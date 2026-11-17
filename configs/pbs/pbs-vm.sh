#!/usr/bin/env bash
# pbs-vm.sh — PBS VM 900 on NUC-2 (Stage G). Interactive: asks for the PBS ISO and
# the USB HDD by-id path (and remembers them). The USB HDD is passed through as a
# whole block device, backup=0. [R3 R6]
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
need_root

ISO_DIR="/var/lib/vz/template/iso"
PBS_ISO="proxmox-backup-server_4.2-1.iso"           # pinned; bump from https://www.proxmox.com/en/downloads
PBS_ISO_URL="https://enterprise.proxmox.com/iso/${PBS_ISO}"
mkdir -p "$ISO_DIR"

# Use an existing PBS ISO if one's already here; otherwise offer to fetch the pinned one.
existing="$(ls "${ISO_DIR}"/proxmox-backup-server_*.iso 2>/dev/null | head -1 || true)"
if [ -n "$existing" ]; then
  ISO_FILENAME="$(basename "$existing")"
  say "found PBS ISO: ${ISO_FILENAME}"
elif confirm "No PBS ISO in local:iso. Download ${PBS_ISO} (~1.2G) now?"; then
  say "downloading ${PBS_ISO} ..."
  curl -fL --progress-bar "$PBS_ISO_URL" -o "${ISO_DIR}/${PBS_ISO}.part"
  mv "${ISO_DIR}/${PBS_ISO}.part" "${ISO_DIR}/${PBS_ISO}"
  ISO_FILENAME="$PBS_ISO"
  ok "downloaded ${PBS_ISO}"
else
  echo "Upload a PBS ISO to local:iso (or re-run and say yes), then try again."; exit 1
fi
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

ok "PBS VM 900 created and started (booting the installer ISO)."
cat <<EOF

Next:
  1. Proxmox UI -> VM ${VMID} -> Console: run the PBS installer (static 192.168.1.5, gateway .1,
     DNS 192.168.1.4). This graphical install is the one interactive step.
  2. Then finish the rest from this host — no console needed:
       ./configs/pbs/pbs-finalize.sh setup-ssh   # once: authorise an SSH key into PBS
       ./configs/pbs/pbs-finalize.sh finalize      # boot-switch + datastore + retention
  3. Verify:  ./configs/pbs/verify-pbs.sh
EOF
