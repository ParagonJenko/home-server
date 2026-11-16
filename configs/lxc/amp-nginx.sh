#!/usr/bin/env bash
# amp-nginx.sh — LXC 230 (AMP) and LXC 240 (Nginx). Native installs, no Docker,
# so NO --features flags. Neither needs the media mount. [R13 R19 R20]
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
pct exec 240 -- bash -c 'command -v nginx >/dev/null || { apt-get update && apt-get install -y nginx; }'
say "deploy homelab.conf (resolver filled with the Pi, ${PI_IP})"
TMP="$(mktemp)"
sed "s/{{PI_IP}}/${PI_IP}/g" ../nginx/homelab.conf > "$TMP"
pct push 240 "$TMP" /etc/nginx/conf.d/homelab.conf
rm -f "$TMP"
pct exec 240 -- bash -c 'rm -f /etc/nginx/sites-enabled/default && nginx -t && systemctl reload nginx'
ok "nginx 240 up. A passing 'nginx -t' only means syntax — routing needs the Pi resolving *.home."

# --- AMP 230: game-server panel (CubeCoders, vendor-managed) ----------------
create_ct 230 amp 40 2048
pct start 230 2>/dev/null || true
pause "AMP uses CubeCoders' own interactive installer. Enter the container and run it:
   pct enter 230
   then: bash <(curl -fsSL https://cubecoders.com/getamp.sh)   (follow the prompts)
   Add amp.home to network.md's address register once it has a reserved IP."
ok "amp-nginx done (AMP finishes in its installer)."
