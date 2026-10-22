# MAV Control downloads

Release files the MAV Control app and its routing server download, and the static site `prublyda.com` (GitHub Pages, branch `main`, root).

- `latest/mavcontrol-routing-linux-x64.tar.gz` — the current routing-server release, with its `.sha256`.
- `latest/manifest.txt` — the signed release manifest (`version`, `url`, `sha256`, `key`, `signature`); the running servers read it every 10 minutes (from raw.githubusercontent.com, unaffected by Pages) and install a new release on their own once it is signed by the authorised release key.
- `releases/<version>/` — the `.sha256` and manifest of every release that was ever the latest one. The same bytes may also sit on a GitHub Release of this repository (tag `routing-<version>`), uploaded by a local agent; `latest/` is what the running servers follow.

Published by `Tools/RoutingServer/publish-release.sh` from the MAV_Control repository.

## prublyda.com (coordinate links)

- `CNAME`, `.nojekyll` — Pages custom domain; Jekyll off so `.well-known` is served.
- `.well-known/assetlinks.json` (Android App Links) and `.well-known/apple-app-site-association` (iOS Universal Links): `REPLACE_WITH_*` placeholders must be filled (Apple Team ID, release certificate SHA-256) before links open the app.
- `map/index.html` — landing page for `https://prublyda.com/map?mgrs=...` shown when the app does not open.

Source copy and guide: `Tools/Distribution/links/` in MAV_Control. Keep the two in step.
