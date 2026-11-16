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

# 3. LVM-thin autoextend ------------------------------------------------------
# Default lvm.conf leaves this disabled (compiled default threshold=100 = never),
# so a thin pool at 100% aborts writes — the exact corruption R8 designs out.
# Extend at 70% full, grow 20%. Idempotent; skips if an active setting exists.
say "LVM-thin autoextend (R8): threshold 70%, grow 20%"
if grep -qE '^[[:space:]]*thin_pool_autoextend_threshold[[:space:]]*=' /etc/lvm/lvm.conf; then
  ok "  already set ($(lvmconfig activation/thin_pool_autoextend_threshold 2>/dev/null))"
else
  sed -i '/^activation {/a\        thin_pool_autoextend_threshold = 70\n        thin_pool_autoextend_percent = 20' /etc/lvm/lvm.conf
  ok "  enabled: threshold=70 percent=20"
fi
VFREE_PE="$(vgs --noheadings -o vg_free_count pve 2>/dev/null | tr -d ' ' || true)"
[ "${VFREE_PE:-0}" = "0" ] && warn "  NOTE: VG 'pve' has ~0 free extents — autoextend can't grow; the R6 ceilings are the real guard."

# 4. Scoped MCP automation token ----------------------------------------------
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
ENVFILE="$(dirname "$0")/../../mcp/proxmox/proxmox.env"
HOSTIP="$(hostname -I | awk '{print $1}')"

upsert_env() {  # upsert_env KEY VALUE — update in place, else append; keeps other settings
  local k="$1" v="$2"
  if grep -q "^${k}=" "$ENVFILE" 2>/dev/null; then
    sed -i "s|^${k}=.*|${k}=${v}|" "$ENVFILE"
  else
    echo "${k}=${v}" >> "$ENVFILE"
  fi
}

create_token() {  # create the token, record it in proxmox.env, print it once
  local secret
  secret=$(pveum user token add "$TUSER" automation --privsep 0 --output-format json | jq -r '.value')
  mkdir -p "$(dirname "$ENVFILE")"
  if [ -f "$ENVFILE" ]; then
    upsert_env PROXMOX_HOST "$HOSTIP"
    upsert_env PROXMOX_TOKEN_ID "claude@pve!automation"
    upsert_env PROXMOX_TOKEN_SECRET "$secret"
    chmod 600 "$ENVFILE"
    ok "  updated $ENVFILE with the new secret (kept your other settings)."
  else
    cat > "$ENVFILE" <<EOF
PROXMOX_HOST=${HOSTIP}
PROXMOX_PORT=8006
PROXMOX_TOKEN_ID=claude@pve!automation
PROXMOX_TOKEN_SECRET=${secret}
PROXMOX_VERIFY_SSL=false
PROXMOX_READONLY=false
EOF
    chmod 600 "$ENVFILE"
    ok "  wrote $ENVFILE (chmod 600) — the MCP server on THIS box needs no paste."
  fi
  warn "  Running the MCP server on another machine? Copy proxmox.env across."
  hdr "================= MCP API TOKEN — shown once ================="
  echo  "  Token ID:  claude@pve!automation"
  printf '  Secret:    '; save "$secret"
  echo  "============================================================="
  ok    "Written to proxmox.env above; also store it in your vault (R21)."
}

if pveum user token list "$TUSER" --output-format json 2>/dev/null | jq -e '.[]|select(.tokenid=="automation")' >/dev/null; then
  # Token already exists — its secret can't be re-read, so the only way to refill
  # proxmox.env is to rotate. Gated: --rotate-token, or a yes here. A bare re-run
  # (e.g. the bootstrap) keeps the working token untouched.
  if [ "${1:-}" = "--rotate-token" ] || confirm "token ${TUSER}!automation exists — rotate it now (revokes the current secret)?"; then
    pveum user token remove "$TUSER" automation
    warn "  revoked the old token — anything still using it breaks until it takes the new secret."
    create_token
  else
    warn "!! keeping the existing token — its secret was only shown when it was created."
    echo "   Put your saved copy into ${ENVFILE}, or re-run with --rotate-token to regenerate."
  fi
else
  create_token
fi

ok "stage-a done."
