#!/usr/bin/env bash
# set-qbit-pass.sh — set the qBittorrent WebUI password through qBittorrent's own API
# (so qBittorrent does the hashing — no fragile PBKDF2 editing). Runs INSIDE LXC 210.
#   pct exec 210 -- bash /opt/media-pipeline/set-qbit-pass.sh
#
# It bootstraps by logging in with the temporary password qBittorrent prints on startup
# (or the password already in .env, so re-running works), sets a new generated password,
# writes it to .env, and prints it once for your vault.
set -euo pipefail
ENV_FILE="/opt/media-pipeline/.env"
QB="http://localhost:8080"
G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; Z=$'\e[0m'

# Current password candidates, newest first: the temp password from the log, then
# whatever is already in .env (lets you re-run after it's been set).
TMP_PW="$(cd /opt/media-pipeline && docker compose logs qbittorrent 2>&1 \
  | grep -i 'temporary password' | tail -1 | awk '{print $NF}' | tr -d '[:space:]')"
CUR_PW="$(sed -n 's/^QBIT_PASS=//p' "$ENV_FILE" 2>/dev/null | head -1)"

NEW_PW="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"

python3 - "$QB" "$NEW_PW" "$TMP_PW" "$CUR_PW" <<'PY'
import sys, json, urllib.parse, urllib.request, http.cookiejar
base, new = sys.argv[1], sys.argv[2]
candidates = [c for c in sys.argv[3:] if c]
cj = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
def post(path, fields):
    req = urllib.request.Request(base + path, data=urllib.parse.urlencode(fields).encode())
    req.add_header("Referer", base)   # qBittorrent's WebUI CSRF check
    return op.open(req, timeout=15).read().decode()
for pw in candidates:
    try:
        if post("/api/v2/auth/login", {"username": "admin", "password": pw}).strip() == "Ok.":
            break
    except Exception:
        pass
else:
    sys.exit("could not log in with the temp password or the one in .env")
post("/api/v2/app/setPreferences", {"json": json.dumps({"web_ui_password": new})})
print("set")
PY

# Record + print the new password.
touch "$ENV_FILE"
grep -q '^QBIT_USER=' "$ENV_FILE" && sed -i 's|^QBIT_USER=.*|QBIT_USER=admin|' "$ENV_FILE" || echo 'QBIT_USER=admin' >> "$ENV_FILE"
grep -q '^QBIT_PASS=' "$ENV_FILE" && sed -i "s|^QBIT_PASS=.*|QBIT_PASS=${NEW_PW}|" "$ENV_FILE" || echo "QBIT_PASS=${NEW_PW}" >> "$ENV_FILE"

echo "${G}qBittorrent password set via API.${Z}  login: admin"
echo "${Y}SAVE${Z} this to your vault (won't be shown again):"
echo "   ${NEW_PW}"
