#!/usr/bin/env bash
# stage-b-storage.sh — media pool on the 2×4TB DAS (Stage B). Run as root on NUC-1.
# Interactive: it shows your disks, you pick the two DAS disks, it confirms before
# wiping, and remembers them in ~/.homelab.env. DESTRUCTIVE. [R1 R8 R9]
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
need_root

echo "Pick the TWO DAS disks. Check their size/model against the internal SSD first."
pick_disk DAS_1 "First DAS disk"
pick_disk DAS_2 "Second DAS disk"
[ "$DAS_1" = "$DAS_2" ] && { echo "!! same disk twice — aborting."; exit 1; }
confirm "WIPE $DAS_1 and $DAS_2 and build the media pool?" || { echo "aborted."; exit 1; }

# TODO: wipe + format both ext4 (reserved-blocks >=5%, R8); mount /mnt/pool/disk{1,2};
#       build mergerfs at /mnt/media (see ../mergerfs/fstab-snippet, keep torrents/ and
#       library/ on the SAME branch so Arr imports hardlink); create the shared media
#       user 1000:1000 and the torrents/ + library/ tree.
echo "Chosen: $DAS_1  $DAS_2 — implement the format/mount/mergerfs logic per rules.md B2."
echo "Record each disk's model/serial/by-id in storage.md's disk register."
