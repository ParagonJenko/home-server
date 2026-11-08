#!/usr/bin/env bash
# bootstrap-nuc1.sh — one command for NUC-1 (Beelink S13).
# Runs Stage A → B → C, then (after the Pi's DNS exists) the media stack E,
# prompting for values and pausing at the manual bits. Each terminal command is
# shown and confirmed. Safe to re-run — just skip what's already done.
set -euo pipefail
cd "$(dirname "$0")"
source configs/lib/common.sh
need_root

echo "=== NUC-1 bootstrap ==="
pause "Prereq: Proxmox VE 9.2 installed on NUC-1 (Stage A1), DAS attached."
ask PI_IP "The Pi's IP (used by every container)" 192.168.1.4

run ./configs/lxc/stage-a-host-setup.sh            # A2–A3: repos, tools, MCP token
pause "Copy the printed API token into your Proxmox MCP config AND your vault (shown once)."

run ./configs/lxc/stage-b-storage.sh               # B: pick disks, build the pool (destructive)
pause "Fill test (B3) runs a while — start it when ready: ./configs/mergerfs/filltest.sh"

run ./configs/lxc/stage-c-template.sh              # C: Debian LXC template

echo
echo ">> The media stack (E) needs DNS. If you haven't run ./bootstrap-pi.sh yet, do it now."
confirm "Is the Pi's DNS up (Stage D done)?" || { echo "Run ./bootstrap-pi.sh, then re-run me."; exit 0; }

run ./configs/lxc/media-pipeline.sh                # E1
pause "Inside LXC 210: ./configs/lxc/_install-docker.sh, push the compose, up -d, then arr-setup.py"
run ./configs/lxc/plex.sh                          # E2
pause "Sign in to Plex; add libraries at /library/movies and /library/tv"
run ./configs/lxc/amp-nginx.sh                     # E3

echo "=== NUC-1 done. Next: ./bootstrap-nuc2.sh, then the Pi's monitoring (Stage H). ==="
