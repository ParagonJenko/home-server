#!/usr/bin/env bash
# cloudflared.sh — LXC 112 on NUC-2: a Cloudflare Tunnel that exposes ONLY the HA-MCP endpoint
# (Home Assistant's MCP server on :9584), so Claude can reach HA over MCP without putting HA's
# login UI on the internet. Outbound-only (no inbound ports opened). Unprivileged.
# The optional named-tunnel token lives in the gitignored configs/cloudflared/.env, set on-box —
# boxes pull only, nothing is committed (R21). Co-located with HA (VM 910) + Frigate (CT 111) on
# NUC-2 so a tunnel restart never touches the media stack. [R13 R20 R21]
# Run as root on NUC-2.
set -euo pipefail
cd "$(dirname "$0")"
source ../lib/common.sh
source ./_require_filled.sh; source ./_template.sh
need_root

CTID=112
NS="192.168.1.4"        # the Pi (R13)

if pct status "$CTID" >/dev/null 2>&1; then
  warn "CT ${CTID} already exists — skipping create."
else
  say "create CT ${CTID} — cloudflared (HA-MCP tunnel)"
  pct create "$CTID" "$(resolve_template)" \
    --hostname cloudflared --cores 1 --memory 256 --swap 256 \
    --rootfs "local-lvm:4" --unprivileged 1 --features nesting=1 \
    --onboot 1 --startup order=4 --nameserver "$NS" \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp
fi
pct start "$CTID" 2>/dev/null || true

say "install cloudflared (static binary, arch-matched)"
# pct exec has a minimal PATH that excludes /usr/local/bin, so test the binary by its
# absolute path, not `command -v` (which would re-download every run and then fail the check).
pct exec "$CTID" -- bash -c '
  set -e
  command -v curl >/dev/null || { apt-get update && apt-get install -y curl ca-certificates; }
  if [ ! -x /usr/local/bin/cloudflared ]; then
    arch="$(dpkg --print-architecture)"   # amd64 | arm64
    curl -fsSL -o /usr/local/bin/cloudflared \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
    chmod +x /usr/local/bin/cloudflared
  fi
  /usr/local/bin/cloudflared --version'

# ---- target + optional token: gitignored .env, set on-box (boxes pull only) ----
if [ ! -f ../cloudflared/.env ]; then
  say "cloudflared target — stored in configs/cloudflared/.env (gitignored)"
  echo "Point it at the HA-MCP 'local network access' endpoint. Enable that in HA → HA-MCP"
  echo "integration → Configure → local network access (default HA is 192.168.1.25:9584)."
  envset ../cloudflared/.env HA_MCP_URL "HA-MCP URL [blank = http://192.168.1.25:9584]"
  echo "For a STABLE hostname paste a Cloudflare Tunnel token; blank = quick tunnel"
  echo "(instant *.trycloudflare.com, changes on restart)."
  envset ../cloudflared/.env CLOUDFLARED_TUNNEL_TOKEN "Cloudflare Tunnel token (blank = quick)" --secret
else
  say "configs/cloudflared/.env present — keeping it."
fi

say "deploy run wrapper + systemd unit + .env"
pct exec "$CTID" -- mkdir -p /opt/cloudflared
pct push "$CTID" ../cloudflared/run.sh            /opt/cloudflared/run.sh
pct exec "$CTID" -- chmod +x /opt/cloudflared/run.sh
pct push "$CTID" ../cloudflared/cloudflared.service /etc/systemd/system/cloudflared.service
pct push "$CTID" ../cloudflared/.env              /opt/cloudflared/.env
pct exec "$CTID" -- chmod 600 /opt/cloudflared/.env
pct exec "$CTID" -- bash -c 'systemctl daemon-reload && systemctl enable --now cloudflared && sleep 4 && systemctl is-active cloudflared || true'

ok "cloudflared ${CTID} up. Get the public URL:  ./configs/cloudflared/get-url.sh"
