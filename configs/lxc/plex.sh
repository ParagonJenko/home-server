#!/usr/bin/env bash
# plex.sh — LXC 220: Plex with a read-only library mount. [R6]
# Library path is /library/movies and /library/tv — identical on host, LXC and
# inside the container (matches storage.md). Do NOT remap to /movies /tv.
# Root disk 32G (metadata + thumbnails + transcode scratch live in /config).
set -euo pipefail
cd "$(dirname "$0")"
source ./_require_filled.sh; source ./_template.sh; source ./_idmap.sh; source ./_requires_mount.sh; source ./_tailscale-tun.sh

CTID=220
# TODO: pct create ${CTID} ... --rootfs local-lvm:32 --mp0 /mnt/media,mp=/data ...
#   pass /dev/dri for hardware transcode (remove the compose `devices:` line if no iGPU)
apply_idmap "$CTID"
apply_requires_mount "$CTID" /mnt/media
apply_tailscale_tun "$CTID"   # Plex runs Tailscale directly for remote access (R20)
echo "plex: push plex/docker-compose.yaml, up -d, then add libraries at /library/movies and /library/tv."
