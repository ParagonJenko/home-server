#!/usr/bin/env bash
# stage-a-host-setup.sh — Proxmox host base (step A2). Run as root on each NUC. [R19]
#   1. switch to the no-subscription apt repo (drop enterprise)
#   2. install base tools
#   3. create the scoped MCP automation token (ClaudeAutomation role + claude@pve)
# Idempotent — safe to re-run.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
need_root

ROLE=ClaudeAutomation
TUSER=claude@pve
# Guest lifecycle + config + allocate guest-disk space + read-only audit.
# Deliberately NO Sys.Console / Sys.Modify (host root) and NO VM.Console / VM.Monitor
# (shell inside a guest) — the token builds guests, it never reaches inside one. [A2]
PRIVS="Datastore.Audit Datastore.AllocateSpace Pool.Audit Sys.Audit VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.PowerMgmt VM.Snapshot"

# 1. No-subscription repo ------------------------------------------------------
say "apt: drop the enterprise repo, ensure pve-no-subscription"
for f in /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/pve-enterprise.list \
         /etc/apt/sources.list.d/ceph.sources /etc/apt/sources.list.d/ceph.list; do
  [ -e "$f" ] && { mv "$f" "$f.disabled"; echo "  disabled $f"; }
done
# a unified proxmox.sources may carry an enterprise component — neutralise any that do
if grep -rlsq 'enterprise.proxmox.com' /etc/apt/sources.list.d/ 2>/dev/null; then
  grep -rls 'enterprise.proxmox.com' /etc/apt/sources.list.d/ | while read -r f; do
    mv "$f" "$f.disabled"; echo "  disabled $f"; done
fi
if ! grep -rqs 'pve-no-subscription' /etc/apt/sources.list.d/ /etc/apt/sources.list 2>/dev/null; then
  . /etc/os-release
  cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${VERSION_CODENAME}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
  echo "  added pve-no-subscription (${VERSION_CODENAME})"
fi
apt update

# 2. Base tools ----------------------------------------------------------------
say "install base tools"
apt -y install curl git jq lsb-release

# 3. Scoped MCP automation token ----------------------------------------------
say "role ${ROLE} (verify it has no Sys.Console)"
if pveum role list --output-format json | jq -e --arg r "$ROLE" '.[]|select(.roleid==$r)' >/dev/null; then
  pveum role modify "$ROLE" --privs "$PRIVS"
else
  pveum role add "$ROLE" --privs "$PRIVS"
fi

say "user ${TUSER} + ACL at /"
pveum user list --output-format json | jq -e --arg u "$TUSER" '.[]|select(.userid==$u)' >/dev/null \
  || pveum user add "$TUSER"
pveum aclmod / --user "$TUSER" --role "$ROLE"

say "API token"
if pveum user token list "$TUSER" --output-format json 2>/dev/null | jq -e '.[]|select(.tokenid=="automation")' >/dev/null; then
  warn "!! token ${TUSER}!automation already exists — its secret is only shown once."
  echo "   Lost it? Run:  pveum user token remove ${TUSER} automation   then re-run this script."
else
  SECRET=$(pveum user token add "$TUSER" automation --privsep 0 --output-format json | jq -r '.value')
  hdr "================= MCP API TOKEN — shown once ================="
  echo  "  Token ID:  claude@pve!automation"
  printf '  Secret:    '; save "$SECRET"
  echo  "============================================================="
  ok    "Put the Token ID + Secret into your Proxmox MCP config AND your vault (R21)."
fi

ok "stage-a done."
