#!/usr/bin/env bash
# media-pipeline.sh — LXC 210: qBittorrent + the whole Arr stack in one container. [R6 R13]
# Unprivileged, nesting+keyctl, /mnt/media bind-mounted at /data, idmap, requires-mount.
# Run as root on NUC-1.
set -euo pipefail
cd "$(dirname "$0")"
source ../lib/common.sh
source ./_require_filled.sh; source ./_template.sh; source ./_idmap.sh; source ./_requires_mount.sh
need_root

CTID=210
NS="192.168.1.4"        # the Pi — the one literal IP a config may carry (R13)
ROOTFS_CAP=20           # GB on local-lvm (storage.md ceiling; downloads live on the pool, not here)

if pct status "$CTID" >/dev/null 2>&1; then
  warn "CT ${CTID} already exists — skipping create (idmap/mount re-applied below)."
else
  say "create CT ${CTID} — media-pipeline (qBittorrent + Arr stack)"
  pct create "$CTID" "$(resolve_template)" \
    --hostname media-pipeline \
    --cores 2 --memory 2048 --swap 512 \
    --rootfs "local-lvm:${ROOTFS_CAP}" \
    --mp0 /mnt/media,mp=/data \
    --unprivileged 1 --features nesting=1,keyctl=1 \
    --onboot 1 --startup order=3 \
    --nameserver "$NS" \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp
fi

apply_idmap "$CTID"                         # container 1000 -> host 1000 (shared media user)
apply_requires_mount "$CTID" /mnt/media     # refuse to start if the pool isn't mounted (R9)

say "start CT ${CTID} + install Docker"
pct start "$CTID" 2>/dev/null || true
pct push "$CTID" ./_install-docker.sh /root/_install-docker.sh
pct exec "$CTID" -- bash -c 'command -v docker >/dev/null || bash /root/_install-docker.sh'

say "deploy the compose stack"
pct exec "$CTID" -- mkdir -p /opt/media-pipeline
pct push "$CTID" ../media-pipeline/docker-compose.yaml /opt/media-pipeline/docker-compose.yaml
if [ -f ../media-pipeline/.env ]; then
  pct push "$CTID" ../media-pipeline/.env /opt/media-pipeline/.env
else
  warn "  ENTER: ../media-pipeline/.env not found — create it (secrets-init.sh) before the stack is useful."
fi
pct exec "$CTID" -- bash -c 'cd /opt/media-pipeline && docker compose up -d'

ok "media-pipeline up. Next: ../media-pipeline/arr-setup.py --apply  (wires the Arrs over their APIs)."
