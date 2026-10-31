#!/usr/bin/env bash
# Run as root on the existing routing host. No PPA or player/server rebuild.
# Usage: bash install-valhalla.sh [region-pbf-url]; default is the FULL Ukraine extract.
set -Eeuo pipefail
PBF_URL="${1:-https://download.geofabrik.de/europe/ukraine-latest.osm.pbf}"
IMAGE=ghcr.io/valhalla/valhalla@sha256:18cb42988e03c70dc4bc4ca095a259ec4db5e5df928be65956fc1c64c280b47a
DATA=/var/lib/valhalla
CONFIG=/etc/mavcontrol-routing
UNIT=/etc/systemd/system/valhalla.service
MIN_FREE_KIB=$((3 * 1024 * 1024))
[[ $EUID == 0 && $(uname -m) == x86_64 ]] || { echo 'Requires root on x86_64 Linux.' >&2; exit 1; }
command -v flock >/dev/null
mkdir -p "$DATA/generations"
exec 9>"$DATA/deploy.lock"
flock -n 9 || { echo 'Another Valhalla deployment owns this host.' >&2; exit 1; }
GEN=$(mktemp -d "$DATA/generations/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
ID=$(basename "$GEN" | tr '[:upper:]' '[:lower:]')
PHASE=preflight
ACTIVE_CONTAINER=
PROBE="mav-valhalla-probe-$ID"
ACTIVATING=0
ROUTING_CHANGED=0
OLD_UNIT=0
OLD_CURRENT=0
OLD_URL=0
OLD_ACTIVE=0
OLD_ENABLED=0
exec > >(tee -a "$GEN/deploy.log") 2>&1

phase() { PHASE=$1; printf '\nphase=%s utc=%s\n' "$PHASE" "$(date -u +%FT%TZ)"; }
free_kib() { df -Pk "$DATA" | awk 'END {print $4}'; }
disk_guard() { [[ $(free_kib) -ge $MIN_FREE_KIB ]] || { echo 'Less than 3 GiB free; generation preserved.' >&2; return 1; }; }
rollback() {
    local restore_failed=0
    echo 'Restoring the prior Valhalla generation/unit and route URL.'
    systemctl stop valhalla || restore_failed=1
    if [[ $OLD_CURRENT == 1 ]]; then
        ln -s "$(cat "$GEN/previous-current.txt")" "$DATA/.rollback-$ID"
        mv -Tf "$DATA/.rollback-$ID" "$DATA/current" || restore_failed=1
    elif [[ -L $DATA/current ]]; then mv "$DATA/current" "$GEN/failed-current-link" || restore_failed=1; fi
    if [[ $OLD_UNIT == 1 ]]; then cp -a "$GEN/previous-valhalla.service" "$UNIT" || restore_failed=1
    elif [[ -e $UNIT || -L $UNIT ]]; then mv "$UNIT" "$GEN/failed-valhalla.service" || restore_failed=1; fi
    systemctl daemon-reload || restore_failed=1
    if [[ $OLD_ENABLED == 0 ]]; then systemctl disable valhalla || restore_failed=1; fi
    if [[ $OLD_ACTIVE == 1 ]]; then systemctl start valhalla || restore_failed=1; fi
    if [[ $ROUTING_CHANGED == 1 ]]; then
        if [[ $OLD_URL == 1 ]]; then cp -a "$GEN/previous-valhalla.url" "$CONFIG/valhalla.url" || restore_failed=1
        elif [[ -e $CONFIG/valhalla.url ]]; then mv "$CONFIG/valhalla.url" "$GEN/failed-valhalla.url" || restore_failed=1; fi
        systemctl restart mavcontrol-routing || restore_failed=1
    fi
    return "$restore_failed"
}
failed() {
    local status=$1 line=$2
    trap - ERR INT TERM
    set +e
    printf 'FAILED phase=%s line=%s exit=%s; evidence=%s\n' "$PHASE" "$line" "$status" "$GEN" >&2
    printf 'phase=%s line=%s exit=%s\n' "$PHASE" "$line" "$status" > "$GEN/failed.txt"
    if [[ -n $ACTIVE_CONTAINER ]]; then podman stop --time 10 "$ACTIVE_CONTAINER"; fi
    if command -v podman >/dev/null && podman container exists "$PROBE"; then
        podman logs "$PROBE" > "$GEN/probe.failed.log" 2>&1
        podman inspect "$PROBE" > "$GEN/probe.failed.container.json"
        podman stop --time 10 "$PROBE"
    fi
    if [[ $ACTIVATING == 1 ]]; then rollback > "$GEN/rollback.log" 2>&1; echo "rollback_exit=$?"; fi
    exit "$status"
}
trap 'failed $? $LINENO' ERR
trap 'failed 130 $LINENO' INT
trap 'failed 143 $LINENO' TERM
[[ -d $CONFIG ]] || { echo 'Existing routing config folder is required.' >&2; false; }
systemctl is-active --quiet mavcontrol-routing
[[ ! -e $DATA/current || -L $DATA/current ]] || { echo 'current must be absent or a symlink.' >&2; false; }
cp -- "$0" "$GEN/installer.source.sh"
disk_guard


phase swap
# Reuse the bootstrap's active swap; never allocate a second file when 4 GiB is already active.
SWAP_KIB=$(awk 'NR>1 {n+=$3} END {print n+0}' /proc/swaps)
# mkswap reserves a header page; tolerate its sub-MiB accounting difference.
if [[ $SWAP_KIB -lt $((4 * 1024 * 1024 - 1024)) ]]; then
    SWAP="$DATA/mav-valhalla.swap"
    if [[ -e $SWAP ]]; then
        [[ $(stat -c %s "$SWAP") == 4294967296 && $(blkid -s TYPE -o value "$SWAP") == swap ]]
        if awk -v p="$SWAP" 'NR>1 && $1==p {found=1} END {exit !found}' /proc/swaps; then
            echo 'Existing owned swap is active but total capacity is insufficient.' >&2; false
        fi
    else
        [[ $(free_kib) -ge $((MIN_FREE_KIB + 4 * 1024 * 1024)) ]]
        fallocate -l 4G "$SWAP"
        chmod 600 "$SWAP"
        mkswap "$SWAP"
    fi
    swapon "$SWAP"
    cp -a /etc/fstab "$GEN/fstab.before"
    if ! awk -v p="$SWAP" '$1==p {found=1} END {exit !found}' /etc/fstab; then
        printf '%s none swap sw 0 0\n' "$SWAP" >> /etc/fstab
    fi
fi
disk_guard

if ! command -v podman >/dev/null || ! command -v curl >/dev/null || ! command -v python3 >/dev/null; then
    phase dependencies
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y podman curl ca-certificates python3
fi
PODMAN=$(command -v podman)

phase image
podman pull "$IMAGE"
podman image inspect "$IMAGE" > "$GEN/image.json"
disk_guard
mkdir -p "$GEN/tmp" "$GEN/timezone-work"
cat > "$GEN/request.json" <<'JSON'
{"locations":[{"lat":50.45,"lon":30.52},{"lat":49.84,"lon":24.03}],"costing":"auto"}
JSON

# Every builder has its own name and retained container/logs. The monitor can stop ONLY that builder.
run_cli() {
    local name=$1 status=0 cli_pid monitor_pid
    shift
    phase "$name"
    disk_guard
    ACTIVE_CONTAINER="mav-valhalla-$ID-$name"
    nice -n 15 ionice -c 2 -n 7 podman run --name "$ACTIVE_CONTAINER" --pull=never \
        --network=host --cpus=.75 --cpu-shares=128 --memory=384m --memory-swap=4608m --pids-limit=256 \
        --label "io.mavcontrol.valhalla.generation=$ID" \
        -v "$GEN:/data" -w /data/timezone-work -e TMPDIR=/data/tmp "$IMAGE" "$@" \
        > "$GEN/$name.stdout" 2> "$GEN/$name.stderr" &
    cli_pid=$!
    (
        trap - ERR
        while kill -0 "$cli_pid" 2>/dev/null; do
            if [[ $(free_kib) -lt $MIN_FREE_KIB ]]; then
                echo 'Builder stopped at the 3 GiB free-disk floor.' > "$GEN/$name.resource-failure"
                podman stop --time 10 "$ACTIVE_CONTAINER"
                break
            fi
            sleep 2
        done
    ) &
    monitor_pid=$!
    if wait "$cli_pid"; then status=0; else status=$?; fi
    wait "$monitor_pid"
    printf 'exit=%s\n' "$status" > "$GEN/$name.exit"
    if podman container exists "$ACTIVE_CONTAINER"; then podman inspect "$ACTIVE_CONTAINER" > "$GEN/$name.container.json"; fi
    ACTIVE_CONTAINER=
    [[ $status == 0 && ! -e $GEN/$name.resource-failure ]]
    disk_guard
}

phase download
curl --fail --location --retry 3 --connect-timeout 20 --max-time 3600 \
    --dump-header "$GEN/pbf.headers" "$PBF_URL" -o "$GEN/region.osm.pbf.part"
mv "$GEN/region.osm.pbf.part" "$GEN/region.osm.pbf"
sha256sum "$GEN/region.osm.pbf" > "$GEN/pbf.sha256"
disk_guard
run_cli config valhalla_build_config --mjolnir-tile-dir /data/tiles --mjolnir-tile-extract /data/tiles.tar \
    --mjolnir-timezone /data/tz.sqlite --mjolnir-admin /data/admin.sqlite --mjolnir-concurrency 1 \
    --mjolnir-max-cache-size 134217728 --httpd-service-listen tcp://127.0.0.1:8002 --loki-use-connectivity false
cp "$GEN/config.stdout" "$GEN/valhalla.json"
run_cli timezones valhalla_build_timezones
mv "$GEN/timezones.stdout" "$GEN/tz.sqlite"
run_cli admins valhalla_build_admins -c /data/valhalla.json /data/region.osm.pbf
run_cli sqlite python3 -c '
import sqlite3
for path,table in [("/data/tz.sqlite","tz_world"),("/data/admin.sqlite","admins")]:
    db=sqlite3.connect("file:"+path+"?mode=ro",uri=True)
    db.enable_load_extension(True); db.load_extension("mod_spatialite"); db.enable_load_extension(False)
    assert db.execute("PRAGMA integrity_check").fetchone()[0]=="ok", path
    assert db.execute("SELECT count(*) FROM "+table).fetchone()[0]>0, path
    db.close()
print("timezone_and_admin_integrity=ok")'
run_cli tiles valhalla_build_tiles -c /data/valhalla.json /data/region.osm.pbf
run_cli extract valhalla_build_extract -c /data/valhalla.json -v
[[ -s $GEN/tiles.tar ]]
sha256sum "$GEN/valhalla.json" "$GEN/tz.sqlite" "$GEN/admin.sqlite" "$GEN/tiles.tar" > "$GEN/dataset.sha256"

python3 - "$GEN" <<'PY'
import json,pathlib,socket,sys
p=pathlib.Path(sys.argv[1]); c=json.loads((p/"valhalla.json").read_text())
c["httpd"]["service"]["listen"]="tcp://127.0.0.1:18002"
(p/"valhalla.probe.json").write_text(json.dumps(c))
with socket.socket() as s: s.bind(("127.0.0.1",18002))
PY
route_check() {
    local port=$1 name=$2 http
    curl --silent --show-error --max-time 15 --dump-header "$GEN/$name.headers" \
        --output "$GEN/$name.json" --write-out '%{http_code}' -H 'Content-Type: application/json' \
        --data-binary "@$GEN/request.json" "http://127.0.0.1:$port/route" > "$GEN/$name.http"
    http=$(<"$GEN/$name.http")
    [[ $http == 200 ]]
    python3 - "$GEN/$name.json" <<'PY'
import json,sys
t=json.load(open(sys.argv[1]))["trip"]
assert t["status"]==0 and t["summary"]["length"]>0 and t["summary"]["time"]>0
assert len(t["locations"])==2 and t["legs"] and all(leg.get("shape") for leg in t["legs"])
print("Kyiv_Lviv_route=ok km="+str(t["summary"]["length"])+" seconds="+str(t["summary"]["time"]))
PY
}
ready() {
    local port=$1 name=$2 attempt
    for attempt in {1..30}; do
        if curl --fail --silent --show-error --max-time 2 "http://127.0.0.1:$port/status" > "$GEN/$name.status.json" 2> "$GEN/$name.status.stderr"; then return; fi
        sleep 1
    done
    echo 'Valhalla did not become ready.' >&2
    return 1
}

phase probe
podman run -d --name "$PROBE" --pull=never --network=host --cpus=.75 --memory=384m --memory-swap=1536m \
    --pids-limit=256 --read-only --tmpfs /tmp:rw,size=64m -v "$GEN:/data:ro" \
    --label "io.mavcontrol.valhalla.generation=$ID" "$IMAGE" valhalla_service /data/valhalla.probe.json 1
ready 18002 probe
route_check 18002 probe-route
podman logs "$PROBE" > "$GEN/probe.log" 2>&1
podman stop --time 10 "$PROBE"

phase activate
if [[ -e $UNIT || -L $UNIT ]]; then cp -a "$UNIT" "$GEN/previous-valhalla.service"; OLD_UNIT=1; fi
if [[ -L $DATA/current ]]; then readlink "$DATA/current" > "$GEN/previous-current.txt"; OLD_CURRENT=1; fi
if [[ -e $CONFIG/valhalla.url ]]; then cp -a "$CONFIG/valhalla.url" "$GEN/previous-valhalla.url"; OLD_URL=1; fi
if systemctl is-active --quiet valhalla; then OLD_ACTIVE=1; fi
if systemctl is-enabled --quiet valhalla; then OLD_ENABLED=1; fi
ACTIVATING=1
if [[ $OLD_ACTIVE == 1 ]]; then systemctl stop valhalla; fi
if podman container exists mav-valhalla-runtime; then echo 'Runtime container name is occupied; refusing replacement.' >&2; false; fi
ln -s "$GEN" "$DATA/.current-$ID"
mv -Tf "$DATA/.current-$ID" "$DATA/current"
cat > "$GEN/valhalla.service" <<UNITFILE
[Unit]
Description=Valhalla routing engine (pinned image, loopback only)
After=network.target
[Service]
ExecStart=$PODMAN run --rm --name mav-valhalla-runtime --pull=never --network=host --cpus=.75 --memory=384m --memory-swap=1536m --pids-limit=256 --read-only --tmpfs /tmp:rw,size=64m -v $DATA/current:/data:ro $IMAGE valhalla_service /data/valhalla.json 1
ExecStop=$PODMAN stop --time 10 mav-valhalla-runtime
Restart=on-failure
TimeoutStopSec=30
Delegate=yes
[Install]
WantedBy=multi-user.target
UNITFILE
install -m 644 "$GEN/valhalla.service" "/etc/systemd/system/.valhalla.service-$ID"
mv -Tf "/etc/systemd/system/.valhalla.service-$ID" "$UNIT"
systemctl daemon-reload
systemctl enable valhalla
systemctl restart valhalla
ready 8002 engine
route_check 8002 engine-route
phase gateway
printf 'http://127.0.0.1:8002/route\n' > "$CONFIG/.valhalla.url-$ID"
mv -Tf "$CONFIG/.valhalla.url-$ID" "$CONFIG/valhalla.url"
ROUTING_CHANGED=1
systemctl restart mavcontrol-routing
python3 - <<'PY'
import socket,time
for attempt in range(30):
    try:
        with socket.create_connection(("127.0.0.1",14669),timeout=1): break
    except OSError:
        time.sleep(1)
else: raise RuntimeError("Routing gateway did not open its existing TCP listener")
PY
route_check 14669 gateway-route
systemctl is-active --quiet mavcontrol-routing
systemctl is-active --quiet valhalla
printf 'image=%s\ngeneration=%s\nresult=engine_and_gateway_route_passed\n' "$IMAGE" "$GEN" > "$GEN/completed.txt"
ACTIVATING=0
echo "Valhalla verified through the routing gateway; generation retained: $GEN"
