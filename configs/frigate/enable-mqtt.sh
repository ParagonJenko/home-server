#!/usr/bin/env bash
# enable-mqtt.sh — turn on Frigate→HA MQTT. Prompts for the broker credentials (the HA user you made
# for Frigate), writes them to the gitignored .env, and flips config.yaml's mqtt block to enabled.
# Run AFTER installing the Mosquitto broker add-on in HA and creating the MQTT user. Then redeploy
# with frigate.sh. Run from the repo. [R21]
set -euo pipefail
cd "$(dirname "$0")"                       # configs/frigate
CFG=config.yaml
ENVF=.env

echo "== Enable Frigate → HA MQTT =="
echo "Prereq: the Mosquitto broker add-on is installed in HA and you've made an MQTT user"
echo "(Settings → People → Users → add e.g. 'frigate'). Enter that user's login below."
echo

read -rp  "  MQTT username [frigate]: " u; u="${u:-frigate}"
read -rsp "  MQTT password: " p; echo
[ -n "$p" ] || { echo "No password given — aborting (nothing changed)." >&2; exit 1; }

# 1. creds -> .env (upsert, keep the RTSP lines)
tmp="$(mktemp)"
grep -v -E '^FRIGATE_MQTT_(USER|PASSWORD)=' "$ENVF" 2>/dev/null > "$tmp" || :
{ cat "$tmp"; printf 'FRIGATE_MQTT_USER=%s\nFRIGATE_MQTT_PASSWORD=%s\n' "$u" "$p"; } > "$ENVF"
rm -f "$tmp"; chmod 600 "$ENVF"
echo "  creds saved to configs/frigate/.env (gitignored)"

# 2. flip the mqtt: block in config.yaml to the enabled form (replaces enabled:false + its comments)
python3 - "$CFG" <<'PY'
import re, sys
f = sys.argv[1]
s = open(f).read()
block = ('mqtt:\n'
         '  enabled: true\n'
         '  host: homeassistant.home.alexjenkinson.com\n'
         '  user: "{FRIGATE_MQTT_USER}"\n'
         '  password: "{FRIGATE_MQTT_PASSWORD}"\n')
# the mqtt: block runs from `mqtt:` through all following indented / comment / blank lines
new, n = re.subn(r'(?ms)^mqtt:\n(?:[ \t#].*\n|\n)*', block, s, count=1)
if n != 1:
    sys.stderr.write("could not find the mqtt: block in config.yaml — enable it by hand.\n"); sys.exit(2)
open(f, 'w').write(new)
print("  config.yaml: mqtt enabled (host homeassistant.home.alexjenkinson.com)")
PY

# sanity: config.yaml still parses
python3 -c "import yaml,sys; yaml.safe_load(open('$CFG'))" \
  && echo "  config.yaml valid" || { echo "config.yaml failed to parse — check it." >&2; exit 2; }

cat <<'EOF'

Done. Commit the config change (non-secret) and redeploy:
  git add configs/frigate/config.yaml && git commit -m "frigate: enable MQTT to HA" && git push
  # on NUC-2:
  cd ~/home-server && git pull && ./configs/lxc/frigate.sh && ./configs/frigate/verify-frigate.sh

Then in HA: HACS → install the Frigate integration → Add Integration → Frigate →
URL http://frigate-lxc.home.alexjenkinson.com:8971. camera.* + binary_sensor.*_motion/_person appear.
EOF
