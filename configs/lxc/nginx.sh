#!/usr/bin/env bash
# nginx.sh — LXC 240: the reverse proxy. Native nginx, no Docker (no --features),
# no media mount. Staged for HTTPS but NOT switched live here — the wildcard cert needs
# your Cloudflare token, so enable-tls.sh (a manual step) issues it and flips nginx to
# :443. Until then nginx serves its default site, so it starts cleanly either way. [R13 R19 R20]
# Run as root on NUC-1.
set -euo pipefail
cd "$(dirname "$0")"
source ../lib/common.sh
source ./_require_filled.sh; source ./_template.sh
need_root

CTID=240
NS="192.168.1.4"        # the Pi (R13)
PI_IP="192.168.1.4"     # the one literal IP a config may carry — fills the resolver line

if pct status "$CTID" >/dev/null 2>&1; then
  warn "CT ${CTID} already exists — skipping create."
else
  say "create CT ${CTID} — nginx (reverse proxy)"
  pct create "$CTID" "$(resolve_template)" \
    --hostname nginx --cores 1 --memory 512 --swap 512 \
    --rootfs "local-lvm:8" --unprivileged 1 \
    --onboot 1 --startup order=2 --nameserver "$NS" \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp
fi
pct start "$CTID" 2>/dev/null || true
pct exec "$CTID" -- bash -c 'command -v nginx >/dev/null || { apt-get update && apt-get install -y nginx openssl curl; }'

say "stage the proxy config + TLS tooling in /opt/nginx (NOT live yet — cert comes first)"
pct exec "$CTID" -- mkdir -p /opt/nginx
TMP="$(mktemp)"
sed "s/{{PI_IP}}/${PI_IP}/g" ../nginx/homelab.conf > "$TMP"   # fill the resolver before it ships
pct push "$CTID" "$TMP" /opt/nginx/homelab.conf
rm -f "$TMP"
pct push "$CTID" ../nginx/ssl.conf        /opt/nginx/ssl.conf
pct push "$CTID" ../nginx/enable-tls.sh   /opt/nginx/enable-tls.sh
pct push "$CTID" ../nginx/verify-nginx.sh /opt/nginx/verify-nginx.sh
ok "nginx ${CTID} up — serving default site; proxy config + TLS tooling staged in /opt/nginx."
