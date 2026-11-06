# MAV Control downloads

Release files the MAV Control app and its routing server download, and the static site `prublyda.com` (GitHub Pages, branch `main`, root).

- `latest/manifest.txt` — the signed release manifest (`version`, `url`, `sha256`, `release`, `expires`, `key`, `signature`, `signature2`); the running servers read it every 10 minutes (from raw.githubusercontent.com, unaffected by Pages) and install a new release on their own once it is signed by the authorised release key, is not older than the newest release they accepted (`release` only goes up) and has not expired. Manifests published before 2026-11-06 have no `release`, `expires` or `signature2`.
- The routing-server tarball `mavcontrol-routing-linux-x64.tar.gz` is an asset of the GitHub Release `routing-<version>` of this repository, and the manifest's `url` points there, so git carries only text. Releases published before 2026-11-06 also left a copy in `latest/`; the first numbered release removes it from the tip (the history keeps it).
- `latest/mavcontrol-routing-linux-x64.tar.gz.sha256` and `releases/<version>/` — the `.sha256` and manifest of the latest release and of every release before it.

Published by `Tools/RoutingServer/publish-release.sh` from the MAV_Control repository.

## prublyda.com (coordinate links)

- `CNAME`, `.nojekyll` — Pages custom domain; Jekyll off so `.well-known` is served.
- `.well-known/assetlinks.json` (Android App Links) and `.well-known/apple-app-site-association` (iOS Universal Links): `REPLACE_WITH_*` placeholders must be filled (Apple Team ID, release certificate SHA-256) before links open the app.
- `map/index.html` — landing page for `https://prublyda.com/map?mgrs=...` shown when the app does not open.

Source copy and guide: `Tools/Distribution/links/` in MAV_Control. Keep the two in step.
