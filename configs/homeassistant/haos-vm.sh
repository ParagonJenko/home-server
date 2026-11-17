#!/usr/bin/env bash
# haos-vm.sh — Home Assistant OS VM 910 on NUC-2 (Stage G).
# HAOS ships a prebuilt UEFI qcow2 image (no installer ISO): download it, import it
# as the boot disk, start. This build has NO Zigbee/Z-Wave USB radio, so there is no
# device passthrough — Matter/Zigbee here are network-attached (a LAN coordinator or
# cloud integrations). Add a USB dongle later with `qm set 910 --usb0 host=<id>` and
# the VM then pins to whichever host it's plugged into.
# Static address is a DHCP reservation + DNS name (R13), never baked into the VM.
# Run as root on NUC-2.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
need_root

VMID=910
HAOS_VER="18.3"          # bump to latest: https://github.com/home-assistant/operating-system/releases
IMG="haos_ova-${HAOS_VER}.qcow2"
URL="https://github.com/home-assistant/operating-system/releases/download/${HAOS_VER}/${IMG}.xz"
STORAGE="local-lvm"
MEM=4096                 # HAOS min is 2048; 4096 leaves room for add-ons. Drop to 2048 if NUC-2 RAM is tight.

if qm status "$VMID" >/dev/null 2>&1; then
  warn "VM ${VMID} already exists — skipping create."
  exit 0
fi
confirm "Create Home Assistant OS VM ${VMID} (HAOS ${HAOS_VER}) on this host?" || exit 1

# Download + decompress to scratch on /var/lib/vz (has real disk space, unlike /tmp).
WORK="$(mktemp -d /var/lib/vz/haos.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
say "download HAOS ${HAOS_VER} image"
curl -fL "$URL" -o "${WORK}/${IMG}.xz"
unxz -f "${WORK}/${IMG}.xz"        # -> ${WORK}/${IMG}

say "create VM ${VMID} — UEFI/q35, qemu-agent, onboot"
qm create "$VMID" \
  --name homeassistant \
  --cores 2 --memory "$MEM" \
  --ostype l26 \
  --machine q35 \
  --bios ovmf \
  --scsihw virtio-scsi-single \
  --net0 virtio,bridge=vmbr0 \
  --onboot 1 --startup order=4 \
  --agent enabled=1

# import-from (PVE 8+/9) imports the qcow2 into a new volume and attaches it as scsi0
# in one step — no disk-name guessing. HAOS is UEFI, so it also needs an EFI vars disk.
say "import the HAOS image as scsi0 + add the EFI vars disk"
qm set "$VMID" --scsi0 "${STORAGE}:0,import-from=${WORK}/${IMG}"
qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=0"
qm set "$VMID" --boot order=scsi0
qm resize "$VMID" scsi0 32G        # HAOS grows its data partition to fill the disk on first boot

qm start "$VMID"
ok "Home Assistant OS ${VMID} started (give it ~2 min on first boot)."
echo "   Onboard at:  http://homeassistant.home.alexjenkinson.com:8123   (or the VM's IP until DNS is set)"
echo "   R13: add a DHCP reservation for VM ${VMID} -> 192.168.1.25 + the AdGuard rewrite (Stage D)."
echo "   R4:  it's a guest, so the PBS backup job already covers it — no extra wiring."
echo "   Verify: ./configs/homeassistant/verify-ha.sh"
