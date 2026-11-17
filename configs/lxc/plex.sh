#!/usr/bin/env bash
# plex.sh — LXC 220: Plex with a read-only library mount. [R6]
# Library path is /library/movies and /library/tv — identical on host, LXC and
# inside the container (matches storage.md). Do NOT remap to /movies /tv.
# Root disk 32G (metadata + thumbnails + transcode scratch live in /config).
# Run as root on NUC-1.
set -euo pipefail
cd "$(dirname "$0")"
source ../lib/common.sh
source ./_require_filled.sh; source ./_template.sh; source ./_idmap.sh; source ./_requires_mount.sh; source ./_tailscale-tun.sh
need_root

CTID=220
NS="192.168.1.4"        # the Pi (R13)

if pct status "$CTID" >/dev/null 2>&1; then
  warn "CT ${CTID} already exists — skipping create (idmap/mount/tun re-applied below)."
else
  say "create CT ${CTID} — Plex (read-only library mount)"
  pct create "$CTID" "$(resolve_template)" \
    --hostname plex-lxc \
    --cores 2 --memory 2048 --swap 512 \
    --rootfs "local-lvm:32" \
    --mp0 /mnt/media,mp=/data,ro=1 \
    --unprivileged 1 --features nesting=1,keyctl=1 \
    --onboot 1 --startup order=4 \
    --nameserver "$NS" \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp
fi

apply_idmap "$CTID"
apply_requires_mount "$CTID" /mnt/media
apply_tailscale_tun "$CTID"     # Plex runs Tailscale directly for remote access (R20)

# Hardware transcode: bind the iGPU into the container. Remove the compose `devices:`
# line (and this block) if the NUC has no usable iGPU / render node.
CONF="/etc/pve/lxc/${CTID}.conf"
if [ -e /dev/dri ] && ! grep -q 'dev/dri' "$CONF"; then
  say "pass /dev/dri through for hardware transcode"
  cat >> "$CONF" <<'EOF'
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
EOF
fi

say "start CT ${CTID} + install Docker"
pct start "$CTID" 2>/dev/null || true
pct push "$CTID" ./_install-docker.sh /root/_install-docker.sh
pct exec "$CTID" -- bash -c 'command -v docker >/dev/null || bash /root/_install-docker.sh'

say "deploy the compose stack"
pct exec "$CTID" -- mkdir -p /opt/plex
pct push "$CTID" ../plex/docker-compose.yaml /opt/plex/docker-compose.yaml
pct push "$CTID" ../plex/verify-plex.sh /opt/plex/verify-plex.sh
[ -f ../plex/.env ] && pct push "$CTID" ../plex/.env /opt/plex/.env
pct exec "$CTID" -- bash -c 'cd /opt/plex && docker compose up -d'

ok "plex up — compose stack running; verify-plex.sh pushed to /opt/plex."
