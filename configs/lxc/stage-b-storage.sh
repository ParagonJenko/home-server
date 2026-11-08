#!/usr/bin/env bash
# stage-b-storage.sh — media pool on the 2×4TB DAS (B2–B5). Run as root on NUC-1.
# DESTRUCTIVE: wipes the two disks named below. Edit SDX/SDY to your real DAS disks
# and double-check them against the internal SSD FIRST. [R1 R8 R9]
set -euo pipefail
source "$(dirname "$0")/_require_filled.sh"

# Ship as placeholders on purpose — a realistic default like /dev/sdX slips past the guard.
SDX="<first-DAS-disk>"
SDY="<second-DAS-disk>"

require_block_device "$SDX"
require_block_device "$SDY"

# TODO: wipe + format both disks ext4 (keep reserved-blocks ≥5%, R8),
#       mount at /mnt/pool/disk1 and /mnt/pool/disk2,
#       build the mergerfs pool at /mnt/media (see ../mergerfs/fstab-snippet),
#       create the shared `media` user (1000:1000) + torrents/ and library/ siblings.
# torrents/ and library/ MUST land on the same branch so Arr imports hardlink, not copy.
echo "stage-b: fill in per rules.md B2–B5, then run the hardlink test (D1) and fill test (B6)."
