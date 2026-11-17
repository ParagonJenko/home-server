#!/usr/bin/env bash
# amp-nginx.sh — LXC 230 (AMP) and LXC 240 (Nginx). Native installs, no Docker,
# so NO --features flags. Neither needs the media mount. [R13 R19 R20]
# Nginx gets staged for HTTPS but is NOT switched live here: the wildcard cert needs
# your Cloudflare token, so enable-tls.sh (a manual step) issues it and flips nginx to
# :443. Until then nginx serves its default site, so it starts cleanly either way.
# Run as root on NUC-1.
set -euo pipefail
cd "$(dirname "$0")"
source ../lib/common.sh
source ./_require_filled.sh; source ./_template.sh
need_root

NS="192.168.1.4"        # the Pi (R13)
PI_IP="192.168.1.4"     # the one literal IP a config may carry — fills the resolver line

create_ct() {           # create_ct <id> <hostname> <rootfs_gb> <memory_mb>
  local id="$1" host="$2" cap="$3" mem="$4"
  if pct status "$id" >/dev/null 2>&1; then
    warn "CT ${id} already exists — skipping create."
    return
  fi
  say "create CT ${id} (${host})"
  pct create "$id" "$(resolve_template)" \
    --hostname "$host" --cores 1 --memory "$mem" --swap 512 \
    --rootfs "local-lvm:${cap}" --unprivileged 1 \
    --onboot 1 --startup order=2 --nameserver "$NS" \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp
}

# --- Nginx 240: the reverse proxy ------------------------------------------
create_ct 240 nginx 8 512
pct start 240 2>/dev/null || true
pct exec 240 -- bash -c 'command -v nginx >/dev/null || { apt-get update && apt-get install -y nginx openssl curl; }'

say "stage the proxy config + TLS tooling in /opt/nginx (NOT live yet — cert comes first)"
pct exec 240 -- mkdir -p /opt/nginx
TMP="$(mktemp)"
sed "s/{{PI_IP}}/${PI_IP}/g" ../nginx/homelab.conf > "$TMP"   # fill the resolver before it ships
pct push 240 "$TMP" /opt/nginx/homelab.conf
rm -f "$TMP"
pct push 240 ../nginx/ssl.conf        /opt/nginx/ssl.conf
pct push 240 ../nginx/enable-tls.sh   /opt/nginx/enable-tls.sh
pct push 240 ../nginx/verify-nginx.sh /opt/nginx/verify-nginx.sh
ok "nginx 240 up (serving its default site). TLS is one manual step away:"
echo "   1. Cloudflare -> My Profile -> API Tokens -> Create Token:"
echo "      'Edit zone DNS' template, Zone -> DNS -> Edit, scoped to alexjenkinson.com."
echo "   2. Issue the wildcard + go live (replace <token>):"
echo "      pct exec 240 -- env CF_Token=<token> bash /opt/nginx/enable-tls.sh"
echo "   3. Verify:  pct exec 240 -- bash /opt/nginx/verify-nginx.sh"
echo "   Store the Cloudflare token in your vault (R21)."

# --- AMP 230: game-server panel (CubeCoders, vendor-managed) ----------------
create_ct 230 amp 40 2048
pct start 230 2>/dev/null || true
# CubeCoders' installer is fetched with curl — the base template has none.
pct exec 230 -- bash -c 'command -v curl >/dev/null || { apt-get update && apt-get install -y curl ca-certificates; }'
pct exec 230 -- mkdir -p /opt/amp
pct push 230 ../amp/verify-amp.sh /opt/amp/verify-amp.sh
pause "AMP uses CubeCoders' own interactive installer — run it inside the container:
   1. pct enter 230
   2. bash <(curl -fsSL https://cubecoders.com/getamp.sh)
   3. Answer the prompts: let it create the 'amp' user and install the ADS (the controller).
   4. When asked for a licence, paste your AMP key (free tier covers one instance —
      sign up at cubecoders.com/AMP). Then let it finish and 'exit' the container.
   5. Note the panel URL it prints (default http://<amp-ip>:8080).
   6. Give amp a DHCP reservation + AdGuard rewrite, and add it to network.md (R13).
   Verify:  pct exec 230 -- bash /opt/amp/verify-amp.sh"
ok "amp-nginx done. Finish AMP in its installer, then issue the nginx cert (steps above)."
