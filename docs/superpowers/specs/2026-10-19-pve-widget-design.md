# pve desktop widgets: design

Date: 2026-10-19.

## Intent

Two macOS desktop widgets that show at a glance how loaded the Proxmox host `pve` and its guests are. This is for understanding load, not for alerting. Placed side by side, they take about half of the screen.

## Goals

- See host and guest load, temperatures and free disk space without opening the Proxmox UI.
- Switch the history period between 24h, 1w and 1m on both widgets at once.
- Thresholds visible on charts by line color.

## Non-goals

- Notifications, alerts, sounds.
- Hosts other than `pve` (no other hosts are planned).
- Controlling VMs (start/stop) from the widget.
- Refresh faster than WidgetKit allows: a few minutes is fine.

## Anti-goals

- Anything that needs regular maintenance on pve, or opens pve to the LAN or internet.
- Storing Proxmox credentials on the Mac.

## Environment (verified 2026-10-19)

- pve: Minisforum MS-02 Ultra, Proxmox VE 9.2.21, kernel 7.0, 24 CPUs, 125 GiB RAM, Python 3.13.5. Tailscale `pve.example.ts.net`, no `tailscale serve` config yet. SSH: `ssh pve` (root). Confirm before risky changes on pve and back up files before editing them.
- Guests now: QEMU 100 `vm-legacy`, 101 `win-test` (Windows), 102 `vm-tools`, 103 `vm-hub`; LXC 104 `ct-home`, 105 `ct-app`. Templates 9000, 9001 (stopped). 1-2 more guests may be added.
- All QEMU guests have a working guest agent: `pvesh get /nodes/pve/qemu/<id>/agent/get-fsinfo` returns per-filesystem used/total bytes. LXC disk usage comes from `/nodes/pve/lxc/<id>/status/current` (`disk`, `maxdisk`).
- `pvesh get .../rrddata --timeframe day|week|month` works for the node and for guests. Day = 1440 points at 1 min; month = 1440 points at 30 min. Node fields include `cpu`, `maxcpu`, `loadavg`, `memused`, `memtotal`, `swapused`, `swaptotal`; guest fields include `cpu`, `mem`, `maxmem`, `memhost`, `netin`, `netout`, `diskread`, `diskwrite`.
- `sensors -j` works (it prints harmless `temp1_max_alarm` errors to stderr). Sensors: `coretemp-isa-0000` (CPU package), `nvme-pci-*` (two NVMe: Samsung 970 EVO Plus 2 TB = `vmdata`, Crucial P310 1 TB = OS), `spd5118-i2c-0-50..53` (four DIMMs, high 55 °C), `ice-pci-0100` (E810), RTL8127, `acpitz`.
- Storages to show: `vmdata` (lvmthin 1.54 T, main VM/CT storage), `local-lvm` (lvmthin), `local`/root.
- Mac: macOS 26.6.2, Xcode 27.0. Signing: a paid Apple Developer team (Developer ID and Apple Development certificates).

## Architecture (decided)

1. **Collector service on pve.** A small service that gathers everything locally (`pvesh`, `sensors -j`, guest agent fsinfo) and serves one JSON document. No API token needed because it runs as root locally.
2. **Access only over the tailnet** via `tailscale serve` with a real Tailscale HTTPS certificate. The service itself listens on `127.0.0.1` only.
3. **macOS app + widget extension** (SwiftUI, WidgetKit, Swift Charts, AppIntents). Two widget kinds, both `systemExtraLarge`: **Host** and **Guests**. The container app exists to host the widgets; a minimal settings/preview window is fine.
4. Widgets fetch the JSON on their timeline refresh (every few minutes, whatever WidgetKit grants). If pve is unreachable, show the last data with a "data from HH:MM" mark.

## Widget content (decided)

Mockup: `.superpowers/brainstorm/*/content/layout-b-v2.html` (layout) and `thresholds.html` option A (chart style).

**Shared period switch** `24h · 1w · 1m` as a segmented control on top of **both** widgets. Tapping it on either widget changes the period for both (shared state in an App Group, then reload all timelines). Default period: 24h.

**Host widget**
- CPU: big number = now; next to it avg and peak for the period, and load average; line chart for the period.
- RAM: big number = used now / total; swap used; line chart for the period.
- Temperatures, current: CPU package, both NVMe (labelled by model), four DIMMs, E810.
- Storages, current: `vmdata`, `local-lvm`, root as bars with size.
- Header: host name, uptime, time of the data.

**Guests widget**
- One card per running guest (VM or LXC), sorted by VMID or load (builder's call). Templates are hidden. Stopped guests show as a grey card.
- Card: name, type + VMID, CPU now, small CPU chart for the period with avg and peak, RAM used/max now, free disk space now (largest/root filesystem from guest agent, or LXC rootfs).
- Must fit 6 guests now and up to 8.

**Chart thresholds:** the line changes color by value (green below the warning level, yellow between warning and critical, red above), with the fill under the line tinted the same way (Swift Charts gradient mapped to the Y axis).

**Visual style:** native macOS 26 Liquid Glass widget appearance.

**Desaturated mode (decided by user):** when other windows are in front, macOS shows desktop widgets desaturated and the threshold colors fade. This is acceptable; no extra non-color threshold cues are needed. The widget must still render correctly in that mode (use `widgetAccentable` / rendering mode where it helps readability).

## Builder's calls (made by Claude, user can change)

- Tap on the Host widget opens the pve web UI (`https://pve.example.ts.net:8006`); tap on a guest card opens that guest's page in the UI.
- Default thresholds, kept in one place, each with a warning and a critical level (yellow / red): CPU load 70% / 90%; RAM 90% / 95% (raised from 80% on 2026-10-19: host RAM sits around 80% and the bars flickered); disk used 80% / 90%; CPU temp 85 / 95 °C. For sensors that report their own limits in `sensors -j` (DIMM 55 / 85 °C from `spd5118-sensors.service`, NVMe, E810) the collector passes those limits through and the app uses them.
- Access control: besides tailnet-only `tailscale serve`, the collector answers only when the `Tailscale-User-Login` header set by Serve is the owner's login. The tailnet also has nodes of other users. No secret is stored on the Mac.
- Disk "now" in guest cards; disk values do not follow the period switch. Temperatures and storages also always show current values.

## Left to the builder

- Language and packaging of the collector (e.g. a Python stdlib HTTP server under systemd), caching so a widget request does not run many `pvesh` calls in a burst, JSON schema.
- How the Windows VM 101 RAM is shown (it has `balloon: 0`, Proxmox reports ~100% used; `memhost` or guest agent data may be better).
- Exact layout, fonts and card grid to fit 8 guests.
- Bundle ids, App Group id, project structure.
