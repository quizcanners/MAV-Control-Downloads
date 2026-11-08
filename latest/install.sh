#!/usr/bin/env bash
# One install script for a new and an existing host (SERVER-ONE-INSTALL-SCRIPT). Run as root, from cloud-init or as one pasted command.
# The config files are already in /etc/mavcontrol-routing (server.key, server.pub, root.pub, directory.json, admin-authority.json, port,
# release.txt "<https url> <sha256>", optional release-feed and release-key.txt); this script never makes or reads private keys.
# It installs the routing service from the release named in release.txt (fail-closed staging, SHA256 checked before anything is
# extracted or moved), ufw, sysctl, the unit, starts it, then decides about Valhalla. Rerunning is safe: nothing existing is replaced
# by different bytes, and a unit that differs from ours stops the run before any change.
# MAV_PREFIX (default empty) puts every path under a folder; Tools/RoutingServer.Tests/install-fixture.sh uses it.
set -Eeuo pipefail
umask 022
P="${MAV_PREFIX:-}"
CONFIG="$P/etc/mavcontrol-routing"
OPT="$P/opt/mavcontrol-routing"
UNIT="$P/etc/systemd/system/mavcontrol-routing.service"
VALHALLA_SHA256="72e4055f6ddd3bc436004e0f1b3f102d1fea24dbe52e4551ce059c01a3bdf6af"   # filled by publish-release.sh with the SHA256 of install-valhalla.sh it publishes
VALHALLA_URL="${MAV_VALHALLA_URL:-https://raw.githubusercontent.com/quizcanners/MAV-Control-Downloads/main/latest/install-valhalla.sh}"
# Valhalla needs real room: below these it is not attempted and the reason is written for the Deploy page (quiz, 2026-11-04:
# "if not enough resources for Valhalla - he says as much, so users will address different ones").
VALHALLA_MIN_RAM_MIB=1900
VALHALLA_MIN_DISK_GIB=10
SERVICE_UNIT='[Unit]
Description=MAV Control routing server
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/opt/mavcontrol-routing/MavControlRoutingServer --config /etc/mavcontrol-routing --install /opt/mavcontrol-routing
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
'
say() { printf 'install.sh: %s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

[[ -n $P || $EUID == 0 ]] || die 'run as root'
for f in server.key server.pub root.pub directory.json release.txt; do [[ -s $CONFIG/$f ]] || die "missing $CONFIG/$f"; done
PORT=$(tr -d '[:space:]' < "$CONFIG/port" 2>/dev/null || true); PORT=${PORT:-14669}
read -r URL SHA < "$CONFIG/release.txt" || true
[[ $URL == https://* && ${#SHA} == 64 ]] || die 'release.txt must hold "<https url> <sha256>"'
if [[ -e $UNIT ]]; then printf '%s' "$SERVICE_UNIT" | cmp -s - "$UNIT" || die "$UNIT exists and differs; not replacing it"; fi

command -v curl >/dev/null || { apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y curl; }

if [[ ! -e $OPT ]]; then
    mkdir -p "$(dirname "$OPT")"
    stage=$(mktemp -d "$(dirname "$OPT")/.mavcontrol-routing-install.XXXXXX")
    trap 'rm -rf -- "$stage"' EXIT
    curl -fsSL -o "$stage/release.tar.gz" "$URL"
    printf '%s  %s\n' "$SHA" "$stage/release.tar.gz" | sha256sum -c - >/dev/null || die 'release SHA256 does not match; nothing installed'
    mkdir "$stage/files"
    tar -xzf "$stage/release.tar.gz" -C "$stage/files"
    [[ -f $stage/files/MavControlRoutingServer ]] || die 'release has no MavControlRoutingServer'
    chmod +x "$stage/files/MavControlRoutingServer"
    mv -T -- "$stage/files" "$OPT"
    say 'routing release installed'
fi
[[ -x $OPT/MavControlRoutingServer ]] || die "$OPT/MavControlRoutingServer is not executable"
if [[ ! -e $UNIT ]]; then mkdir -p "$(dirname "$UNIT")"; printf '%s' "$SERVICE_UNIT" > "$UNIT"; fi

# Firewall and kernel UDP buffers (the service asks for 4 MiB each way; Linux clamps to these limits). Never fails the setup.
if command -v ufw >/dev/null || { apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ufw; }; then
    ufw allow OpenSSH; ufw allow "$PORT/udp"; ufw allow "$PORT/tcp"; ufw --force enable
fi
mkdir -p "$P/etc/sysctl.d"
printf 'net.core.rmem_max=8388608\nnet.core.wmem_max=8388608\n' > "$P/etc/sysctl.d/90-mavcontrol-routing.conf"
sysctl -q -p "$P/etc/sysctl.d/90-mavcontrol-routing.conf" || true

systemctl daemon-reload
systemctl enable --now mavcontrol-routing
systemctl is-active --quiet mavcontrol-routing || die 'mavcontrol-routing did not start'
say 'routing service running; the app now waits for its authenticated presence'

# WireGuard hub (VPN-HUB-ON-ROUTING-SERVER): the kernel module and `wg0` live outside the routing process, so tunnels survive
# every restart, self-update and watchdog exit of the service. This script only brings the interface up with the server key;
# peers are added and removed by the service with `wg set` from the signed directory, never by a wg-quick restart (it drops every
# session). One hub key on every server: a key already in the config folder (made by the deployer, sent by the mesh) is used as is;
# only a first server with none makes one. Never fails the install: the reason goes to wg.unavailable.
WG_PORT=51820; WG_ADDRESS=10.10.10.254/24; WG_MTU=1280
rm -f "$CONFIG/wg.unavailable"
wg_fail() { printf 'no WireGuard hub: %s\n' "$1" > "$CONFIG/wg.unavailable"; say "$1"; }
# Optional (quiz, 2026-11-07: "server should be able to work without WireGuard. But there also should be an option to deploy the WireGuard"):
# the deployer asks for it by creating $CONFIG/wireguard (the app's Deploy WireGuard button, or by hand) and rerunning this script.
if [[ ! -e $CONFIG/wireguard ]]; then
    say 'no WireGuard requested ($CONFIG/wireguard missing); the server runs without a hub'
elif command -v wg >/dev/null || { apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-tools; }; then
    if [[ ! -s $CONFIG/wg-server.key ]]; then (umask 077; wg genkey > "$CONFIG/wg-server.key"); fi
    wg pubkey < "$CONFIG/wg-server.key" > "$CONFIG/wg-server.pub"
    mkdir -p "$P/etc/sysctl.d"
    printf 'net.ipv4.ip_forward=1\n' > "$P/etc/sysctl.d/91-mavcontrol-wg.conf"
    sysctl -q -p "$P/etc/sysctl.d/91-mavcontrol-wg.conf" || true
    printf '%s' "[Unit]
Description=MAV Control WireGuard hub interface (peers come from the routing service)
After=network-online.target
Before=mavcontrol-routing.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'ip link add wg0 type wireguard && wg set wg0 listen-port $WG_PORT private-key /etc/mavcontrol-routing/wg-server.key && ip address add $WG_ADDRESS dev wg0 && ip link set wg0 mtu $WG_MTU up'
ExecStop=/bin/sh -c 'ip link del wg0'

[Install]
WantedBy=multi-user.target
" > "$P/etc/systemd/system/mavcontrol-wg0.service"
    ufw allow "$WG_PORT/udp"; ufw route allow in on wg0 out on wg0
    systemctl daemon-reload
    systemctl enable --now mavcontrol-wg0 || wg_fail 'wg0 did not come up (no kernel module?)'
else
    wg_fail 'wireguard-tools could not be installed'
fi

# The reason, or the pending note, is one file the Deploy page and the server's presence read; it is never an install failure.
if systemctl is-active --quiet mav-valhalla-install; then
    say 'Valhalla installer already running; keeping its status and files'
    exit 0
fi
rm -f "$CONFIG/valhalla.unavailable" "$CONFIG/valhalla.pending"
ram_mib=$(awk '/^MemTotal:/ {print int($2/1024)}' "$P/proc/meminfo" 2>/dev/null || echo 0)
mkdir -p "$P/var/lib"
disk_gib=$(df -Pk "$P/var/lib" | awk 'END {print int($4/1048576)}')
if [[ -e $CONFIG/valhalla.url ]]; then
    say 'Valhalla already configured'
elif [[ ${VALHALLA_SHA256} == @* ]]; then
    printf 'this install.sh was not published with its Valhalla hash\n' > "$CONFIG/valhalla.unavailable"
elif (( ram_mib < VALHALLA_MIN_RAM_MIB )); then
    printf 'no Valhalla: %s MiB RAM, needs %s MiB\n' "$ram_mib" "$VALHALLA_MIN_RAM_MIB" > "$CONFIG/valhalla.unavailable"
elif (( disk_gib < VALHALLA_MIN_DISK_GIB )); then
    printf 'no Valhalla: %s GiB free disk, needs %s GiB\n' "$disk_gib" "$VALHALLA_MIN_DISK_GIB" > "$CONFIG/valhalla.unavailable"
else
    # The map build takes a long time: it runs detached so this script ends and the app can pair; its log is the evidence.
    vs=$(mktemp "$P/var/lib/valhalla-installer.XXXXXX.sh")
    curl -fsSL -o "$vs" "$VALHALLA_URL" && printf '%s  %s\n' "$VALHALLA_SHA256" "$vs" | sha256sum -c - >/dev/null \
        || { rm -f "$vs"; printf 'no Valhalla: installer download or hash failed\n' > "$CONFIG/valhalla.unavailable"; vs=; }
    if [[ -n $vs ]]; then
        printf 'building: started %s\n' "$(date -u +%FT%TZ)" > "$CONFIG/valhalla.pending"
        if systemd-run --unit mav-valhalla-install --property=Type=exec bash -c \
            'status=0; bash "$1" || { status=$?; printf "no Valhalla: build failed %s, see /var/lib/valhalla/generations\n" "$(date -u +%FT%TZ)" > "$3"; }; rm -f -- "$1" "$2"; exit "$status"' \
            _ "$vs" "$CONFIG/valhalla.pending" "$CONFIG/valhalla.unavailable" >/dev/null; then
            say 'Valhalla build started in the background'
        else
            # No worker owns these files when launch fails. Routing is already up and stays usable.
            rm -f -- "$vs" "$CONFIG/valhalla.pending"
            printf 'no Valhalla: background installer could not start; see journalctl -u mav-valhalla-install\n' > "$CONFIG/valhalla.unavailable"
        fi
    fi
fi
[[ -e $CONFIG/valhalla.unavailable ]] && say "$(cat "$CONFIG/valhalla.unavailable")"
exit 0
