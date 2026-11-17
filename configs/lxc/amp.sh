#!/usr/bin/env bash
# amp.sh — LXC 230: AMP (CubeCoders) game-server panel. Native install, no Docker
# (no --features), no media mount. AMP itself is installed by hand via CubeCoders'
# interactive installer (runbook E4). [R13 R19]
# Run as root on NUC-1.
set -euo pipefail
cd "$(dirname "$0")"
source ../lib/common.sh
source ./_require_filled.sh; source ./_template.sh
need_root

CTID=230
NS="192.168.1.4"        # the Pi (R13)

if pct status "$CTID" >/dev/null 2>&1; then
  warn "CT ${CTID} already exists — skipping create."
else
  say "create CT ${CTID} — AMP (game-server panel)"
  pct create "$CTID" "$(resolve_template)" \
    --hostname amp --cores 1 --memory 2048 --swap 512 \
    --rootfs "local-lvm:40" --unprivileged 1 \
    --onboot 1 --startup order=2 --nameserver "$NS" \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp
fi
pct start "$CTID" 2>/dev/null || true
# CubeCoders' installer is fetched with curl — the base template has none.
pct exec "$CTID" -- bash -c 'command -v curl >/dev/null || { apt-get update && apt-get install -y curl ca-certificates; }'
pct exec "$CTID" -- mkdir -p /opt/amp
pct push "$CTID" ../amp/verify-amp.sh /opt/amp/verify-amp.sh
ok "AMP container ${CTID} provisioned — curl + verify script in place."
