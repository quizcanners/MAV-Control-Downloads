# MAV Control downloads

Release files the MAV Control app and its routing server download. Nothing else lives here.

- `latest/mavcontrol-routing-linux-x64.tar.gz` — the current routing-server release, with its `.sha256`.
- `latest/manifest.txt` — the signed release manifest (`version`, `url`, `sha256`, `key`, `signature`); the running servers read it every 10 minutes and install a new release on their own once it is signed by the authorised release key.
- `releases/<version>/` — the `.sha256` and manifest of every release that was ever the latest one.

Published by `Tools/RoutingServer/publish-release.sh` from the MAV_Control repository.
