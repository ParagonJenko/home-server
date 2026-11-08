#!/usr/bin/env bash
# media-pipeline.sh — LXC 210: qBittorrent + the whole Arr stack in one container. [R6 R13]
# Unprivileged, nesting+keyctl, /mnt/media bind-mounted at /data, idmap, requires-mount.
set -euo pipefail
cd "$(dirname "$0")"
source ./_require_filled.sh; source ./_template.sh; source ./_idmap.sh; source ./_requires_mount.sh

CTID=210
# TODO: pct create ${CTID} "$(resolve_template)" \
#   --rootfs local-lvm:<cap> --mp0 /mnt/media,mp=/data \
#   --unprivileged 1 --features nesting=1,keyctl=1 \
#   --onboot 1 --startup order=3 --nameserver <PI_IP> --net0 ...,ip=dhcp
apply_idmap "$CTID"
apply_requires_mount "$CTID" /mnt/media
# pct start ${CTID}; then inside: ./_install-docker.sh, push media-pipeline/docker-compose.yaml, up -d
echo "media-pipeline: then run arr-setup.py (../media-pipeline/arr-setup.py) to wire the Arrs over their APIs."
