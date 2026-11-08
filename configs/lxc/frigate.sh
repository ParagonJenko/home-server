#!/usr/bin/env bash
# frigate.sh — LXC 111 on NUC-2: Frigate NVR. PRIVILEGED (--unprivileged 0
# --features nesting=1) for direct iGPU access; keyctl omitted (privileged
# containers don't need it for Docker). Recordings on local-lvm, capped. [R6 R7 R9 R13]
set -euo pipefail
cd "$(dirname "$0")"
source ./_require_filled.sh; source ./_template.sh

CTID=111
# TODO: pct create ${CTID} "$(resolve_template)" \
#   --unprivileged 0 --features nesting=1 \
#   --rootfs local-lvm:260  (NOT 60 — ~230GB of 14-day motion footage; 60G fills in ~4 days) \
#   --onboot 1 --startup order=3 --nameserver <PI_IP> ...
#   pass through /dev/dri for the iGPU.
# Cameras are addressed by hostname (cam-*.home), never IP. Add reservations + AdGuard
# rewrites BEFORE starting Frigate, or it records nothing.
echo "frigate: push ../frigate/{docker-compose.yaml,config.yaml}, fill ../frigate/.env, up -d."
