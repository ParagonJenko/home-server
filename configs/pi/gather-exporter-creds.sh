#!/usr/bin/env bash
# gather-exporter-creds.sh — interactive setup for the application-exporter credentials.
# Run ON THE PI. It walks every credential one at a time and writes it straight into
# /opt/pi-stack/.env (gitignored, chmod 600). For the values it can find on the boxes (Plex token,
# Arr API keys, usernames) it pre-fills a [suggestion] — press Enter to accept, type to override,
# or leave blank to skip. PVE/PBS tokens are created on request. Passwords are typed hidden.
# Nothing is committed; secrets only ever touch .env (R21).
set -uo pipefail

ENV=/opt/pi-stack/.env
NUC1=192.168.1.2
PBS=192.168.1.5
S="ssh -o ConnectTimeout=6 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
[ -d /opt/pi-stack ] || { echo "Run this on the Pi (/opt/pi-stack not found)." >&2; exit 1; }
touch "$ENV"; chmod 600 "$ENV"

# --- helpers ---------------------------------------------------------------
set_env() { # set_env KEY VALUE  (replace the line in-place, or append)
  python3 - "$ENV" "$1" "$2" <<'PY'
import sys
path, k, v = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines()
out, done = [], False
for l in lines:
    if l.startswith(k + "="): out.append(f"{k}={v}"); done = True
    else: out.append(l)
if not done: out.append(f"{k}={v}")
open(path, "w").write("\n".join(out) + "\n")
PY
}
ask() { # ask KEY "Label" [suggestion]
  local key="$1" label="$2" sug="${3:-}" input
  if [ -n "$sug" ]; then read -rp "  $label [$sug]: " input; input="${input:-$sug}"
  else read -rp "  $label (blank = skip): " input; fi
  if [ -n "$input" ]; then set_env "$key" "$input"; echo "    ✓ $key saved"; else echo "    – $key skipped"; fi
}
ask_secret() { # ask_secret KEY "Label"  (hidden input)
  local key="$1" label="$2" input
  read -rsp "  $label (blank = skip): " input; echo
  if [ -n "$input" ]; then set_env "$key" "$input"; echo "    ✓ $key saved"; else echo "    – $key skipped"; fi
}
yn() {    local a; read -rp "  $1 [Y/n]: " a; [ "${a:-y}" != "n" ] && [ "${a:-y}" != "N" ]; }   # default YES
yn_no() { local a; read -rp "  $1 [y/N]: " a; [ "${a:-n}"  = "y" ] || [ "${a:-n}"  = "Y" ]; }   # default NO

echo "=== Exporter credential setup ===  (writes to $ENV)"
echo "Reading what I can off the boxes first..."

# --- auto-discover read-only values on nuc1 + the Pi -----------------------
declare -A SUG
while IFS='=' read -r k v; do [ -n "${k:-}" ] && SUG["$k"]="$v"; done < <(
  $S "root@$NUC1" bash -s <<'REMOTE' 2>/dev/null
pt=$(pct exec 220 -- bash -c 'f=$(find / -name Preferences.xml 2>/dev/null|head -1); [ -n "$f" ] && grep -o "PlexOnlineToken=\"[^\"]*\"" "$f"' 2>/dev/null | sed 's/.*="//;s/"$//')
[ -n "$pt" ] && echo "PLEX_TOKEN=$pt"
pct exec 210 -- bash -c '
  for f in $(find / -path "*/config.xml" 2>/dev/null); do
    k=$(grep -o "<ApiKey>[^<]*</ApiKey>" "$f" 2>/dev/null|sed "s/<[^>]*>//g"); [ -n "$k" ]||continue
    case "$f" in *[Ss]onarr*) echo "SONARR_API_KEY=$k";; *[Rr]adarr*) echo "RADARR_API_KEY=$k";; *[Pp]rowlarr*) echo "PROWLARR_API_KEY=$k";; esac
  done
  qb=$(find / -name qBittorrent.conf 2>/dev/null|head -1); [ -n "$qb" ] && grep -i "WebUI..Username" "$qb"|head -1|sed "s/.*=/QBIT_USER=/"
' 2>/dev/null
REMOTE
)
AGYAML=/opt/pi-stack/adguard/conf/AdGuardHome.yaml
[ -f "$AGYAML" ] && SUG[ADGUARD_USER]="$(grep -A4 '^users:' "$AGYAML" | grep -m1 'name:' | sed 's/.*name: *//; s/ *$//')"
echo

# --- 1. Proxmox token ------------------------------------------------------
echo "[1] Proxmox (pve-exporter)"
pve_exists=$($S "root@$NUC1" "pveum user token list claude@pve --output-format json 2>/dev/null | grep -q '\"monitoring\"' && echo yes || echo no" 2>/dev/null)
pve_go=0
case "$pve_exists" in
  no)  echo "    no PVE monitoring token yet — creating it."; pve_go=1 ;;
  yes) if yn_no "PVE monitoring token already exists — rotate it (recreate for a fresh value)?"; then pve_go=1; else echo "    – keeping the existing PVE token"; fi ;;
  *)   echo "    !! couldn't reach nuc1 to check."; ask PVE_TOKEN_VALUE "Paste an existing PVE token value" ;;
esac
if [ "$pve_go" = 1 ]; then
  v=$($S "root@$NUC1" bash -s <<'REMOTE' 2>/dev/null
pveum user token remove claude@pve monitoring >/dev/null 2>&1
pveum user token add claude@pve monitoring --privsep 0 --output-format json 2>/dev/null | grep -oP '"value"\s*:\s*"\K[^"]+'
pveum acl modify / --roles PVEAuditor --tokens 'claude@pve!monitoring' >/dev/null 2>&1
REMOTE
)
  [ -n "$v" ] && { set_env PVE_TOKEN_VALUE "$v"; echo "    ✓ PVE_TOKEN_VALUE saved ($v)"; } || echo "    !! token creation failed — does claude@pve exist?"
fi

# --- 2. Plex ---------------------------------------------------------------
echo "[2] Plex"
ask PLEX_TOKEN "Plex token" "${SUG[PLEX_TOKEN]:-}"

# --- 3-5. Arrs -------------------------------------------------------------
echo "[3] Sonarr";   ask SONARR_API_KEY   "Sonarr API key"   "${SUG[SONARR_API_KEY]:-}"
echo "[4] Radarr";   ask RADARR_API_KEY   "Radarr API key"   "${SUG[RADARR_API_KEY]:-}"
echo "[5] Prowlarr"; ask PROWLARR_API_KEY "Prowlarr API key" "${SUG[PROWLARR_API_KEY]:-}"

# --- 6. qBittorrent --------------------------------------------------------
echo "[6] qBittorrent  (or whitelist the Pi in qBit to skip auth — see the runbook)"
ask        QBIT_USER "qBittorrent username" "${SUG[QBIT_USER]:-}"
ask_secret QBIT_PASS "qBittorrent password"

# --- 7. PBS token ----------------------------------------------------------
echo "[7] PBS (pbs-exporter)"
pbs_exists=$($S "root@$PBS" "proxmox-backup-manager user list-tokens root@pam 2>/dev/null | grep -q monitoring && echo yes || echo no" 2>/dev/null)
pbs_go=0
case "$pbs_exists" in
  no)  echo "    no PBS monitoring token yet — creating it."; pbs_go=1 ;;
  yes) if yn_no "PBS monitoring token already exists — rotate it (recreate for a fresh value)?"; then pbs_go=1; else echo "    – keeping the existing PBS token"; fi ;;
  *)   echo "    !! couldn't reach PBS to check."; ask PBS_TOKEN_VALUE "Paste an existing PBS token value" ;;
esac
if [ "$pbs_go" = 1 ]; then
  v=$($S "root@$PBS" bash -s <<'REMOTE' 2>/dev/null
proxmox-backup-manager user delete-token root@pam monitoring >/dev/null 2>&1
proxmox-backup-manager user generate-token root@pam monitoring 2>/dev/null | grep -oP '"value"\s*:\s*"\K[^"]+'
proxmox-backup-manager acl update / Audit --auth-id 'root@pam!monitoring' >/dev/null 2>&1
REMOTE
)
  [ -n "$v" ] && { set_env PBS_TOKEN_VALUE "$v"; echo "    ✓ PBS_TOKEN_VALUE saved ($v)"; } || echo "    !! token creation failed"
fi

# --- 8. AdGuard ------------------------------------------------------------
echo "[8] AdGuard"
ask        ADGUARD_USER "AdGuard username" "${SUG[ADGUARD_USER]:-}"
ask_secret ADGUARD_PASS "AdGuard password"

# --- 9. Home Assistant -----------------------------------------------------
echo "[9] Home Assistant  (enable the Prometheus integration in HA first — see monitoring-exporters.md)"
ask_secret HA_TOKEN "HA long-lived token (HA profile -> Security -> Long-lived access tokens -> Create)"

# --- 10. Tdarr -------------------------------------------------------------
echo "[10] Tdarr  (its cruddb/stats API needs a key; find it in Tdarr's UI, or on nuc1:"
echo "      pct exec 210 -- grep -ioE '\"[a-z_]*key[a-z_]*\":\"[^\"]*\"' /opt/tdarr/configs/Tdarr_Server_Config.json )"
ask TDARR_API_KEY "Tdarr API key" "${SUG[TDARR_API_KEY]:-}"

echo
echo "All saved to $ENV."
if yn "Restart the stack now (docker compose up -d)?"; then
  ( cd /opt/pi-stack && docker compose up -d )
  echo "Done. Check Prometheus → Status → Targets in ~30s."
else
  echo "When ready: cd /opt/pi-stack && docker compose up -d"
fi
