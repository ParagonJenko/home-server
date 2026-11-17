#!/usr/bin/env bash
# gather-exporter-creds.sh — collect every application-exporter credential from the boxes and
# print a ready-to-paste block for /opt/pi-stack/.env. Run this ON THE PI (it SSHes to nuc1 + PBS;
# the Pi already has key access to both via the Home Server key).
#
# Tokens (PVE, PBS) that don't exist yet are CREATED and their one-time value printed. Existing ones
# are left alone — their value can't be shown again, so pass --rotate to delete+recreate and get a
# fresh value. API keys / tokens stored in app config are read out directly. The two WebUI passwords
# (qBittorrent, AdGuard) are hashed on disk and cannot be extracted — you fill those with the
# passwords you log in with.
#
# Secrets print to your terminal ONLY. Nothing is written to disk or committed (R21). When done,
# paste the block into /opt/pi-stack/.env and: cd /opt/pi-stack && docker compose up -d
set -uo pipefail

ROTATE=0; [ "${1:-}" = "--rotate" ] && ROTATE=1
NUC1=192.168.1.2
PBS=192.168.1.5
S="ssh -o ConnectTimeout=6 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

echo "# ==================== paste into /opt/pi-stack/.env ===================="
echo "# (lines starting with # are notes, not values)"
echo

# ---------- nuc1: PVE token + Plex token + Arr API keys + qBit username ----------
echo "# --- from nuc1 ---"
$S "root@$NUC1" "ROTATE=$ROTATE bash -s" <<'REMOTE' || echo "# !! couldn't reach nuc1 (192.168.1.2)"
# Proxmox monitoring token
if [ "${ROTATE:-0}" = 1 ]; then pveum user token remove claude@pve monitoring >/dev/null 2>&1; fi
if pveum user token list claude@pve --output-format json 2>/dev/null | grep -q '"monitoring"'; then
  echo "# PVE_TOKEN_VALUE: token already exists (value can't be re-shown) — re-run with --rotate for a fresh one"
else
  v=$(pveum user token add claude@pve monitoring --privsep 0 --output-format json 2>/dev/null | grep -oP '"value"\s*:\s*"\K[^"]+')
  pveum acl modify / --roles PVEAuditor --tokens 'claude@pve!monitoring' >/dev/null 2>&1
  [ -n "$v" ] && echo "PVE_TOKEN_VALUE=$v" || echo "# PVE_TOKEN_VALUE: creation failed — does user claude@pve exist?"
fi

# Plex token (LXC 220)
pt=$(pct exec 220 -- bash -c 'f=$(find / -name Preferences.xml 2>/dev/null | head -1); [ -n "$f" ] && grep -o "PlexOnlineToken=\"[^\"]*\"" "$f"' 2>/dev/null | sed 's/.*="//; s/"$//')
[ -n "$pt" ] && echo "PLEX_TOKEN=$pt" || echo "# PLEX_TOKEN: not found (Plex not in LXC 220, or Preferences.xml missing)"

# Arr API keys + qBittorrent username (LXC 210)
pct exec 210 -- bash -c '
  for f in $(find / -path "*/config.xml" 2>/dev/null); do
    k=$(grep -o "<ApiKey>[^<]*</ApiKey>" "$f" 2>/dev/null | sed "s/<[^>]*>//g")
    [ -n "$k" ] || continue
    case "$f" in
      *[Ss]onarr*)   echo "SONARR_API_KEY=$k" ;;
      *[Rr]adarr*)   echo "RADARR_API_KEY=$k" ;;
      *[Pp]rowlarr*) echo "PROWLARR_API_KEY=$k" ;;
    esac
  done
  qb=$(find / -name qBittorrent.conf 2>/dev/null | head -1)
  [ -n "$qb" ] && grep -i "WebUI..Username" "$qb" | head -1 | sed "s/.*=/QBIT_USER=/"
' 2>/dev/null || echo "# Arr/qBit: LXC 210 not reachable"
REMOTE
echo

# ---------- PBS: monitoring token ----------
echo "# --- from PBS ---"
$S "root@$PBS" "ROTATE=$ROTATE bash -s" <<'REMOTE' || echo "# !! couldn't reach PBS (192.168.1.5)"
if [ "${ROTATE:-0}" = 1 ]; then proxmox-backup-manager user delete-token root@pam monitoring >/dev/null 2>&1; fi
if proxmox-backup-manager user list-tokens root@pam 2>/dev/null | grep -q monitoring; then
  echo "# PBS_TOKEN_VALUE: token already exists (value can't be re-shown) — re-run with --rotate for a fresh one"
else
  v=$(proxmox-backup-manager user generate-token root@pam monitoring 2>/dev/null | grep -oP '"value"\s*:\s*"\K[^"]+')
  proxmox-backup-manager acl update / Audit --auth-id 'root@pam!monitoring' >/dev/null 2>&1
  [ -n "$v" ] && echo "PBS_TOKEN_VALUE=$v" || echo "# PBS_TOKEN_VALUE: creation failed"
fi
REMOTE
echo

# ---------- Pi (local): AdGuard username ----------
echo "# --- from the Pi (this box) ---"
AGYAML=/opt/pi-stack/adguard/conf/AdGuardHome.yaml
if [ -f "$AGYAML" ]; then
  au=$(grep -A4 '^users:' "$AGYAML" | grep -m1 'name:' | sed 's/.*name: *//; s/ *$//')
  [ -n "$au" ] && echo "ADGUARD_USER=$au" || echo "# ADGUARD_USER: no user found in AdGuardHome.yaml"
else
  echo "# ADGUARD_USER: $AGYAML not found"
fi
echo

# ---------- the two you fill by hand (hashed on disk, can't be read) ----------
echo "# --- fill these with the passwords you log in with ---"
echo "QBIT_PASS="
echo "ADGUARD_PASS="
echo "# ======================================================================="
