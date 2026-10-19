#!/usr/bin/env bash
# Deploy the collector to pve and expose it through Tailscale Serve (idempotent).
# Settings come from the environment or from deploy/local.env (gitignored):
#   PVE_HOST                 ssh host of the Proxmox node (default pve)
#   PVEWIDGET_ALLOWED_LOGIN  Tailscale login allowed to read the snapshot, e.g. user@github
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[ -f "$DIR/local.env" ] && . "$DIR/local.env"

HOST="${PVE_HOST:-pve}"
LOGIN="${PVEWIDGET_ALLOWED_LOGIN:?set PVEWIDGET_ALLOWED_LOGIN}"
COLLECTOR="$(dirname "$DIR")"

ssh "$HOST" 'mkdir -p /opt/pvewidget'
rsync -a --delete --exclude '__pycache__' "$COLLECTOR/pvewidget" "$HOST:/opt/pvewidget/"
rsync -a "$DIR/pvewidget.service" "$HOST:/etc/systemd/system/pvewidget.service"
printf 'PVEWIDGET_ALLOWED_LOGIN=%s\n' "$LOGIN" | ssh "$HOST" 'umask 077 && cat > /etc/pvewidget.env'
ssh "$HOST" 'systemctl daemon-reload && systemctl enable --now pvewidget && systemctl restart pvewidget'
ssh "$HOST" 'tailscale serve --bg --https=9443 http://127.0.0.1:9184'
