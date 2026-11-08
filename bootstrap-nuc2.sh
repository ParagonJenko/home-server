#!/usr/bin/env bash
# bootstrap-nuc2.sh — one command for NUC-2 (Beelink S12 Pro): host base (F),
# Frigate + PBS (G). Run as root. Needs the Pi's DNS (Stage D) already up.
set -euo pipefail
cd "$(dirname "$0")"
source configs/lib/common.sh
need_root

echo "=== NUC-2 bootstrap ==="
pause "Prereq: Proxmox VE 9.2 installed on NUC-2 (Stage F), USB HDD attached, Pi DNS up."
ask PI_IP "The Pi's IP" 192.168.1.4

echo "--- Stage F: host base ---"
run ./configs/lxc/stage-a-host-setup.sh            # repos, tools, MCP token
pause "Copy the printed API token into your MCP config + vault."
run ./configs/lxc/stage-c-template.sh              # template (per-host)
echo "Point NUC-2's resolver at the Pi so pbs.home resolves (Stage H3 does this on the router)."

echo "--- Stage G: Frigate + PBS ---"
./secrets-init.sh                                  # Frigate Eufy RTSP creds (gitignored)
run ./configs/lxc/frigate.sh                       # G1
pause "Add a DHCP reservation + AdGuard rewrite per camera BEFORE Frigate records (cam-*.home)."
run ./configs/pbs/pbs-vm.sh                        # G3: prompts for ISO + USB by-id
pause "Install PBS from the VM console, switch boot off the ISO, run datastore-setup.sh on the VM."
run bash -c 'echo "Then: pvesm add pbs on each NUC (G4), a test restore (G5), and offsite sync (G6)."'

echo "=== NUC-2 done. Finish on the Pi (Stage H), then G/I/J. ==="
