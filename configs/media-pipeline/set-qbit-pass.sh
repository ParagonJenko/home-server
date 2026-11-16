#!/usr/bin/env bash
# set-qbit-pass.sh — set the qBittorrent WebUI password through qBittorrent's own API
# (qBittorrent hashes it; no fragile PBKDF2 editing). Runs INSIDE LXC 210.
#   pct exec 210 -- bash /opt/media-pipeline/set-qbit-pass.sh
#
# Self-healing: it logs in with the temp password qBittorrent prints on startup (or the
# one already in .env), sets a new generated password via the API, and records it. If it
# can't log in with anything — e.g. an earlier bad hash locked it out — it clears the
# stored password so qBittorrent issues a fresh temp one, then retries.
set -euo pipefail
ENV_FILE=/opt/media-pipeline/.env
QBT_CONF=/opt/qbittorrent/config/qBittorrent/qBittorrent.conf
QB=http://localhost:8080
G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; Z=$'\e[0m'

NEW_PW="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"

logs_temp_pw() {
  (cd /opt/media-pipeline && docker compose logs qbittorrent 2>&1) \
    | grep -i 'temporary password' | tail -1 | awk '{print $NF}' | tr -d '[:space:]'
}

# try_set <password>: log in with it; on success set NEW_PW and return 0, else non-zero.
try_set() {
  python3 - "$QB" "$NEW_PW" "$1" <<'PY'
import sys, json, urllib.parse, urllib.request, http.cookiejar
base, new, pw = sys.argv[1], sys.argv[2], sys.argv[3]
if not pw:
    sys.exit(2)
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
def post(path, fields):
    req = urllib.request.Request(base + path, data=urllib.parse.urlencode(fields).encode())
    req.add_header("Referer", base)   # qBittorrent's WebUI CSRF check
    return op.open(req, timeout=15).read().decode()
try:
    if post("/api/v2/auth/login", {"username": "admin", "password": pw}).strip() != "Ok.":
        sys.exit(1)
except Exception:
    sys.exit(1)
post("/api/v2/app/setPreferences", {"json": json.dumps({"web_ui_password": new})})
PY
}

CUR_PW="$(sed -n 's/^QBIT_PASS=//p' "$ENV_FILE" 2>/dev/null | head -1)"
done=0
for pw in "$(logs_temp_pw)" "$CUR_PW" "adminadmin"; do
  if [ -n "$pw" ] && try_set "$pw"; then done=1; break; fi
done

if [ "$done" = 0 ]; then
  echo "${Y}Can't log in — clearing qBittorrent's stored password to get a fresh temp one.${Z}"
  ( cd /opt/media-pipeline && docker compose stop qbittorrent >/dev/null )
  [ -f "$QBT_CONF" ] && sed -i '/^WebUI\\Password_PBKDF2=/d; /^WebUI\\Password_ha1=/d' "$QBT_CONF"
  ( cd /opt/media-pipeline && docker compose start qbittorrent >/dev/null )
  for _ in $(seq 1 20); do
    sleep 3
    for pw in "$(logs_temp_pw)" "adminadmin"; do
      if [ -n "$pw" ] && try_set "$pw"; then done=1; break 2; fi
    done
  done
fi

[ "$done" = 1 ] || { echo "${R}Still can't set the password. Inspect: docker compose logs qbittorrent | tail${Z}"; exit 1; }

touch "$ENV_FILE"
grep -q '^QBIT_USER=' "$ENV_FILE" && sed -i 's|^QBIT_USER=.*|QBIT_USER=admin|' "$ENV_FILE" || echo 'QBIT_USER=admin' >> "$ENV_FILE"
grep -q '^QBIT_PASS=' "$ENV_FILE" && sed -i "s|^QBIT_PASS=.*|QBIT_PASS=${NEW_PW}|" "$ENV_FILE" || echo "QBIT_PASS=${NEW_PW}" >> "$ENV_FILE"

echo "${G}qBittorrent password set via API.${Z}  login: admin"
echo "${Y}SAVE${Z} this to your vault (won't be shown again):"
echo "   ${NEW_PW}"
