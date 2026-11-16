#!/usr/bin/env bash
# set-qbit-pass.sh — generate a qBittorrent WebUI password, install it, and record it.
# Runs INSIDE LXC 210 (it edits qBittorrent's config and restarts the container):
#   pct exec 210 -- bash /opt/media-pipeline/set-qbit-pass.sh
#
# qBittorrent stores the WebUI password as a salted PBKDF2-SHA512 hash, so it can't be
# read back out of the config. Instead we generate a password, write the hash qBittorrent
# expects into qBittorrent.conf, and keep the plaintext in .env (printed once for your
# vault) so arr-setup and qbit_manage can log in. This REPLACES any existing password.
set -euo pipefail
ENV_FILE="/opt/media-pipeline/.env"
QBT_CONF="/opt/qbittorrent/config/qBittorrent/qBittorrent.conf"
G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; Z=$'\e[0m'

[ -f "$QBT_CONF" ] || { echo "${R}$QBT_CONF not found — has qBittorrent booted once?${Z}"; exit 1; }

# A password (URL-safe: no shell/quoting surprises) and the PBKDF2 value qBit stores.
PW="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
PBKDF2="$(python3 - "$PW" <<'PY'
import sys, os, hashlib, base64
salt = os.urandom(16)
dk = hashlib.pbkdf2_hmac('sha512', sys.argv[1].encode(), salt, 100000, 64)
print('@ByteArray(%s:%s)' % (base64.b64encode(salt).decode(), base64.b64encode(dk).decode()))
PY
)"

# qBittorrent rewrites its conf on exit, so stop it before editing.
( cd /opt/media-pipeline && docker compose stop qbittorrent >/dev/null )

python3 - "$QBT_CONF" "$PBKDF2" <<'PY'
import sys
conf, pbkdf2 = sys.argv[1], sys.argv[2]
lines = open(conf).read().splitlines()
lines = [l for l in lines if not l.startswith(('WebUI\\Username=', 'WebUI\\Password_PBKDF2=', 'WebUI\\Password_ha1='))]
out, placed = [], False
for l in lines:
    out.append(l)
    if l.strip() == '[Preferences]' and not placed:
        out.append('WebUI\\Username=admin')
        out.append('WebUI\\Password_PBKDF2="%s"' % pbkdf2)
        placed = True
if not placed:  # no [Preferences] section yet — add one
    out += ['[Preferences]', 'WebUI\\Username=admin', 'WebUI\\Password_PBKDF2="%s"' % pbkdf2]
open(conf, 'w').write('\n'.join(out) + '\n')
PY

( cd /opt/media-pipeline && docker compose start qbittorrent >/dev/null )

# Record the plaintext in .env for arr-setup / qbit_manage (upsert both keys).
touch "$ENV_FILE"
grep -q '^QBIT_USER=' "$ENV_FILE" && sed -i 's|^QBIT_USER=.*|QBIT_USER=admin|' "$ENV_FILE" || echo 'QBIT_USER=admin' >> "$ENV_FILE"
grep -q '^QBIT_PASS=' "$ENV_FILE" && sed -i "s|^QBIT_PASS=.*|QBIT_PASS=${PW}|" "$ENV_FILE" || echo "QBIT_PASS=${PW}" >> "$ENV_FILE"

echo "${G}qBittorrent password set and written to .env.${Z}  login: admin"
echo "${Y}SAVE${Z} this to your vault (it is not stored anywhere readable and won't be shown again):"
echo "   ${PW}"
