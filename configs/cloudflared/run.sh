#!/usr/bin/env bash
# run.sh — launched by cloudflared.service inside LXC 112. Reads /opt/cloudflared/.env and starts
# the right tunnel mode: named (token set) or quick (no token). Exposes only HA_MCP_URL — the
# HA-MCP endpoint — so HA's login UI never goes on the internet.
set -euo pipefail
ENVF=/opt/cloudflared/.env
# shellcheck disable=SC1090
[ -f "$ENVF" ] && . "$ENVF"
HA_MCP_URL="${HA_MCP_URL:-http://192.168.1.25:9584}"
if [ -n "${CLOUDFLARED_TUNNEL_TOKEN:-}" ]; then
  exec cloudflared --no-autoupdate tunnel run --token "$CLOUDFLARED_TUNNEL_TOKEN"
else
  exec cloudflared --no-autoupdate tunnel --url "$HA_MCP_URL"
fi
