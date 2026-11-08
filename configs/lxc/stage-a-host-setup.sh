#!/usr/bin/env bash
# stage-a-host-setup.sh — Proxmox host base (A2–A4). Run as root on each NUC. [R19]
# - switch to the no-subscription repo
# - install base tools
# - create the scoped MCP automation token (ClaudeAutomation role + claude@pve)
set -euo pipefail

# 1. No-subscription repo. DELETE the enterprise repo files rather than rewriting
#    their Components: — a rewritten entry still 401s on every apt update.
#    Fresh PVE 9.2 ISOs sometimes ship a unified proxmox.sources instead of a
#    separate pve-enterprise.sources — remove whichever references an enterprise component.
# TODO: rm the enterprise .sources/.list files; add the pve-no-subscription repo.
apt update

# 2. Base tools
apt -y install curl git jq lsb-release

# 3. Scoped automation token. The role EXCLUDES Sys.Console deliberately (node
#    console = root shell, which would void every restriction). This role CAN
#    create and remove guests (VM.Allocate / VM.Config.Disk) — PBS is the mitigation.
# TODO: pveum role add ClaudeAutomation -privs "VM.Allocate VM.Config.* VM.PowerMgmt VM.Audit Datastore.Audit ..."
# TODO: pveum user add claude@pve; pveum aclmod / -user claude@pve -role ClaudeAutomation
# TODO: pveum user token add claude@pve automation --privsep 0   # COPY THE SECRET — shown once → vault
echo "stage-a: review the TODOs above and fill in per rules.md A2–A4."
