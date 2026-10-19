# mac-widget

macOS desktop widgets (WidgetKit, macOS 26) for a Proxmox VE host reachable over Tailscale:

- **Host**: CPU, RAM, load, temperatures and storages of the node.
- **Guests**: per-VM/CT CPU, RAM and disk.
- **Topology**: how the Mac reaches each of your tailnet nodes (LAN, direct, DERP, peer relay) and the latency.

Charts follow a shared 24h / 1w / 1m switch.

## Components

- `collector/`: stdlib-only Python service on the Proxmox host. It reads `pvesh`, `sensors -j` and guest-agent data and serves one JSON snapshot on `127.0.0.1:9184`. It is exposed only to the tailnet through `tailscale serve` (HTTPS 9443) and answers only to the `Tailscale-User-Login` you allow.
- `tsagent/`: stdlib-only Python LaunchAgent on the Mac. It pings your own tailnet nodes with the `tailscale` CLI and serves the topology on `127.0.0.1:9185` (the sandboxed widget cannot run the CLI itself).
- `app/`: SwiftUI app and widget extension, generated with XcodeGen.

## Setup

Collector (on the Proxmox host, reachable as `ssh pve`):

```sh
echo 'PVEWIDGET_ALLOWED_LOGIN=you@github' > collector/deploy/local.env
collector/deploy/deploy.sh   # PVE_HOST=... to use another ssh host
```

Topology agent (on the Mac):

```sh
cat > tsagent/deploy/local.env <<'ENV'
TSTOPO_PVE_GUESTS=vm-a,ct-b   # nodes drawn under the pve host
TSTOPO_HIDDEN=old-node        # nodes left out
ENV
tsagent/deploy/install.sh
```

App: create `app/Local.xcconfig` (gitignored) to override `app/Config.xcconfig`:

```
DEVELOPMENT_TEAM = ABCDE12345
BUNDLE_ID_PREFIX = com.example
PVE_HOST = pve.your-tailnet.ts.net
```

```sh
cd app && xcodegen generate
xcodebuild -project PveWidget.xcodeproj -scheme PveWidget -destination 'platform=macOS' test
```

`sensors -j` chip names and the storages to show are host-specific; adjust them in `collector/pvewidget/config.py`.

## Tests

```sh
(cd collector && python3 -m unittest)
(cd tsagent && python3 -m unittest)
```
