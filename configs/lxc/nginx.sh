#!/usr/bin/env bash
# nginx.sh — LXC 240: the reverse proxy. Native nginx, no Docker, no media mount.
# --features nesting=1 (not keyctl): Debian 13's systemd 257 needs nesting to boot
# cleanly in an unprivileged LXC; keyctl is Docker-only and not needed here.
# Staged for HTTPS but NOT switched live here — the wildcard cert needs
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
    --rootfs "local-lvm:8" --unprivileged 1 --features nesting=1 \
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
# start page (static, served by the start.home block) — always refresh it
pct exec "$CTID" -- mkdir -p /etc/nginx/startpage
pct push "$CTID" ../nginx/startpage/index.html /etc/nginx/startpage/index.html

# Re-run after TLS is live (cert exists): promote the staged config and reload, so a new
# server block in homelab.conf actually takes effect. Before TLS, enable-tls.sh does this.
if pct exec "$CTID" -- test -f /etc/nginx/conf.d/homelab.conf; then
  say "TLS already live — promote the new homelab.conf + reload (only if nginx -t passes)"
  pct exec "$CTID" -- cp /etc/nginx/conf.d/homelab.conf /etc/nginx/conf.d/homelab.conf.bak
  pct exec "$CTID" -- install -m 644 /opt/nginx/homelab.conf /etc/nginx/conf.d/homelab.conf
  if pct exec "$CTID" -- nginx -t; then
    pct exec "$CTID" -- systemctl reload nginx
    pct exec "$CTID" -- rm -f /etc/nginx/conf.d/homelab.conf.bak
    ok "nginx ${CTID} reloaded with the updated homelab.conf."
  else
    pct exec "$CTID" -- mv /etc/nginx/conf.d/homelab.conf.bak /etc/nginx/conf.d/homelab.conf
    warn "nginx -t FAILED — restored the previous config, nothing reloaded. Fix homelab.conf and re-run."
  fi
else
  ok "nginx ${CTID} up — serving default site; proxy config + TLS tooling staged in /opt/nginx."
fi
