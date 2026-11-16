#!/usr/bin/env bash
# pbs-vm.sh — PBS VM 900 on NUC-2 (Stage G). Interactive: asks for the PBS ISO and
# the USB HDD by-id path (and remembers them). The USB HDD is passed through as a
# whole block device, backup=0. [R3 R6]
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
need_root

echo "ISOs available in local:iso:"; ls /var/lib/vz/template/iso/ 2>/dev/null || echo "  (none — upload the PBS ISO first)"
ask ISO_FILENAME "PBS ISO filename"
pick_by_id USB_BY_ID "2TB USB HDD by-id path (the PBS datastore disk)"
confirm "Create PBS VM 900 — installer ISO $ISO_FILENAME, datastore disk $USB_BY_ID?" || exit 1

if qm status 900 >/dev/null 2>&1; then
  warn "VM 900 already exists — skipping create."
else
  say "create PBS VM 900"
  qm create 900 \
    --name pbs \
    --cores 2 --memory 4096 \
    --ostype l26 \
    --scsihw virtio-scsi-single \
    --scsi0 local-lvm:16 \
    --ide2 "local:iso/${ISO_FILENAME},media=cdrom" \
    --boot order=ide2 \
    --net0 virtio,bridge=vmbr0 \
    --onboot 1
fi
# Pass the whole USB HDD through as a block device. backup=0 — PBS's own datastore
# disk must never be swept into a PVE backup (R3).
say "attach the USB HDD ($USB_BY_ID) as scsi1, backup=0"
qm set 900 --scsi1 "${USB_BY_ID},backup=0"
qm start 900

echo "Now install PBS from the VM console (static 192.168.1.5). Then switch boot off the ISO:"
echo "  qm set 900 --boot order=scsi0 ; qm set 900 --ide2 none"
echo "Then copy configs/pbs/datastore-setup.sh to the PBS VM and run it there."
