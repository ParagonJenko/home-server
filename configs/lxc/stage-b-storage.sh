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

say "install mergerfs"
apt -y install mergerfs

# 1. Format each DAS disk ext4, labelled media-disk1/2. -m 1 keeps the ext4 reserve
#    tiny on purpose — the pool's headroom comes from mergerfs minfreespace (R8),
#    not from a 5% ext4 reserve that would waste ~200G per disk. Idempotent: an
#    existing label means it's already built, so we skip the wipe.
for pair in "1:$DAS_1" "2:$DAS_2"; do
  n="${pair%%:*}"; dev="${pair#*:}"
  if blkid -L "media-disk$n" >/dev/null 2>&1; then
    warn "  media-disk$n already exists — skipping wipe/format."
  else
    say "format $dev -> label media-disk$n (ext4)"
    wipefs -a "$dev"
    mkfs.ext4 -F -m 1 -L "media-disk$n" "$dev"
  fi
  mkdir -p "/mnt/pool/disk$n"
done

# 2. fstab: branch mounts by label (stable across re-plugging), then the pool.
say "write /etc/fstab (branches by label + the mergerfs pool)"
cp /etc/fstab "/etc/fstab.bak.$(date +%s)"
for n in 1 2; do
  grep -q "LABEL=media-disk$n " /etc/fstab \
    || echo "LABEL=media-disk$n  /mnt/pool/disk$n  ext4  defaults,noatime  0 2" >> /etc/fstab
done
if ! grep -q ' /mnt/media ' /etc/fstab; then
  mkdir -p /mnt/media
  cat >> /etc/fstab <<'EOF'
/mnt/pool/disk1:/mnt/pool/disk2  /mnt/media  fuse.mergerfs  defaults,allow_other,use_ino,cache.files=partial,dropcacheonclose=true,category.create=epmff,minfreespace=250G,fsname=mergerfs,x-systemd.requires=/mnt/pool/disk1,x-systemd.requires=/mnt/pool/disk2  0 0
EOF
fi
systemctl daemon-reload
mount -a

# 3. Shared media user + the tree. torrents/ and library/ share ONE branch root so
#    the Arr apps can hardlink on import instead of copying (R1).
say "shared media user (1000:1000) + torrents/ library/"
getent group media >/dev/null || groupadd -g 1000 media
id -u media >/dev/null 2>&1 || useradd -u 1000 -g 1000 -M -s /usr/sbin/nologin media
mkdir -p /mnt/media/torrents /mnt/media/library/movies /mnt/media/library/tv
chown -R 1000:1000 /mnt/media/torrents /mnt/media/library

ok "pool built — expect ~7.2 TiB across the two 4TB disks:"
df -h /mnt/media

hdr "SAVE to storage.md's disk register (so the pool rebuilds by identity, R9):"
lsblk -o NAME,SIZE,MODEL,SERIAL "$DAS_1" "$DAS_2"
save "also record each disk's /dev/disk/by-id/ path:  ls -l /dev/disk/by-id/ | grep -v part"
ok "stage-b done."
