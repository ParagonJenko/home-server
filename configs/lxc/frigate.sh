#!/usr/bin/env bash
# frigate.sh — LXC 111 on NUC-2: Frigate NVR. PRIVILEGED (--unprivileged 0
# --features nesting=1) for direct iGPU access; keyctl omitted (privileged
# containers don't need it for Docker). Recordings on local-lvm, capped. [R6 R7 R9 R13]
# Run as root on NUC-2.
set -euo pipefail
cd "$(dirname "$0")"
source ../lib/common.sh
source ./_require_filled.sh; source ./_template.sh
need_root

CTID=111
NS="192.168.1.4"        # the Pi (R13)

if pct status "$CTID" >/dev/null 2>&1; then
  warn "CT ${CTID} already exists — skipping create (GPU passthrough re-checked below)."
else
  say "create CT ${CTID} — Frigate NVR (privileged)"
  # rootfs 260G, NOT 60 — ~230GB of 14-day motion footage; 60G fills in ~4 days (R7).
  pct create "$CTID" "$(resolve_template)" \
    --hostname frigate-lxc \
    --cores 4 --memory 4096 --swap 512 \
    --rootfs "local-lvm:260" \
    --unprivileged 0 --features nesting=1 \
    --onboot 1 --startup order=3 \
    --nameserver "$NS" \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp
fi

# iGPU for hardware detection/decoding.
CONF="/etc/pve/lxc/${CTID}.conf"
if [ -e /dev/dri ] && ! grep -q 'dev/dri' "$CONF"; then
  say "pass /dev/dri through for the iGPU"
  cat >> "$CONF" <<'EOF'
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
EOF
fi

warn "Cameras are addressed by hostname (cam-*.home.alexjenkinson.com). Add their DHCP reservations AND the"
warn "AdGuard rewrites BEFORE starting Frigate (adguard-rewrites.py --apply), or it records nothing."

say "start CT ${CTID} + install Docker"
pct start "$CTID" 2>/dev/null || true
pct push "$CTID" ./_install-docker.sh /root/_install-docker.sh
pct exec "$CTID" -- bash -c 'command -v docker >/dev/null || bash /root/_install-docker.sh'

say "deploy Frigate compose + config"
pct exec "$CTID" -- mkdir -p /opt/frigate/config
pct push "$CTID" ../frigate/docker-compose.yaml /opt/frigate/docker-compose.yaml
pct push "$CTID" ../frigate/config.yaml /opt/frigate/config/config.yaml    # compose mounts /opt/frigate/config -> /config

# Eufy RTSP creds -> gitignored .env (one user/pass, shared by all four cameras). Prompt once.
if ! grep -q '^FRIGATE_RTSP_PASSWORD=.' ../frigate/.env 2>/dev/null; then
  say "Eufy RTSP credentials — stored in configs/frigate/.env (gitignored, chmod 600). Use FRESH creds (R21)."
  envset ../frigate/.env FRIGATE_RTSP_USER "Eufy RTSP username"
  envset ../frigate/.env FRIGATE_RTSP_PASSWORD "Eufy RTSP password" --secret
else
  say "RTSP creds already in configs/frigate/.env — keeping them."
fi
pct push "$CTID" ../frigate/.env /opt/frigate/.env
pct exec "$CTID" -- bash -c 'cd /opt/frigate && docker compose up -d'

ok "frigate up on NUC-2. Auth UI on :8971 — never expose :5000 (unauthenticated, R13)."
