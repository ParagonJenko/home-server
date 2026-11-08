#!/usr/bin/env bash
# pbs-vm.sh — VM 900 on NUC-2. The 2TB USB HDD is passed through as a block device
# (not an fstab mount — avoids the mount fragility that caused the original incident).
# The datastore disk is attached backup=0 so vzdump never backs up a 2TB disk into the
# datastore living on it. [R3 R6]
set -euo pipefail
cd "$(dirname "$0")"
source ../lxc/_require_filled.sh

ISO_FILENAME="<ISO_FILENAME>"      # PBS ISO in local:iso
USB_BY_ID="<usb-hdd-by-id>"        # ls -l /dev/disk/by-id/ | grep <usb-model>
require_filled ISO_FILENAME "$ISO_FILENAME"
require_block_device "$USB_BY_ID"

# TODO: qm create 900 ... --ide2 local:iso/${ISO_FILENAME},media=cdrom --boot order=ide2
#       qm set 900 --scsi1 ${USB_BY_ID},backup=0     # whole disk as block device
# After installing PBS from the VM console, SWITCH BOOT OFF THE ISO:
#   qm set 900 --boot order=scsi0
#   qm set 900 --ide2 none
echo "pbs-vm: install PBS (static 192.168.1.5), then run datastore-setup.sh ON the PBS VM."
