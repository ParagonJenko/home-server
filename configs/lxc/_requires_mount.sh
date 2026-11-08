#!/usr/bin/env bash
# _requires_mount.sh — make a container REFUSE to start if its media bind-mount
# source isn't mounted, instead of starting against an empty host directory and
# filling the Proxmox SSD. Only for containers with a /data bind mount (210, 220). [R9]
set -euo pipefail

apply_requires_mount() {
  # usage: apply_requires_mount <CTID> <MOUNT_PATH>   e.g. apply_requires_mount 210 /mnt/media
  local ctid="$1" path="${2:-/mnt/media}"
  local dropin="/etc/systemd/system/pve-container@${ctid}.service.d"
  mkdir -p "$dropin"
  cat > "${dropin}/requires-mount.conf" <<EOF
[Unit]
RequiresMountsFor=${path}
EOF
  systemctl daemon-reload
  echo "apply_requires_mount ${ctid}: RequiresMountsFor=${path}"
}
