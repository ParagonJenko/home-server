#!/usr/bin/env bash
# get-url.sh — print the cloudflared tunnel's public URL. Run on NUC-2 (host).
# Quick tunnel: greps the *.trycloudflare.com URL from the service logs.
# Named tunnel: the hostname is whatever you routed in Cloudflare Zero Trust (not printed here).
set -euo pipefail
CTID=112
if pct exec "$CTID" -- bash -c 'grep -q "^CLOUDFLARED_TUNNEL_TOKEN=." /opt/cloudflared/.env 2>/dev/null'; then
  echo "Named tunnel in use — the public URL is the hostname you routed in Cloudflare Zero Trust"
  echo "(Networks → Tunnels → your tunnel → the public hostname pointing at HA_MCP_URL)."
  exit 0
fi
url="$(pct exec "$CTID" -- bash -c 'journalctl -u cloudflared --no-pager 2>/dev/null | grep -oE "https://[a-z0-9-]+\.trycloudflare\.com" | tail -1')"
if [ -n "$url" ]; then
  echo "Quick-tunnel URL: $url"
  echo
  echo "HA-MCP connect URL = ${url}<the /private_... path from HA-MCP → Configure → local access>"
  echo "Paste that into claude.ai → Settings → Connectors → Add custom connector."
else
  echo "No tunnel URL yet — is the service up?  pct exec ${CTID} -- systemctl status cloudflared --no-pager"
fi
