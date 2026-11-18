#!/usr/bin/env bash
# enable-mqtt.sh — store the Frigate→HA MQTT credentials in the gitignored .env. MQTT is already
# enabled in config.yaml (in the repo), so this ONLY writes the broker login locally — nothing is
# committed or pushed (the boxes pull only; secrets never leave the box, R21). Run on NUC-2 after
# installing the Mosquitto broker add-on in HA and making the MQTT user, then redeploy with frigate.sh.
set -euo pipefail
cd "$(dirname "$0")"                       # configs/frigate
ENVF=.env

echo "== Frigate MQTT credentials =="
echo "Prereq: Mosquitto broker add-on installed in HA + an MQTT user made (Settings → People → Users)."
echo
read -rp  "  MQTT username [frigate]: " u; u="${u:-frigate}"
read -rsp "  MQTT password: " p; echo
[ -n "$p" ] || { echo "No password given — aborting (nothing changed)." >&2; exit 1; }

tmp="$(mktemp)"
grep -v -E '^FRIGATE_MQTT_(USER|PASSWORD)=' "$ENVF" 2>/dev/null > "$tmp" || :
{ cat "$tmp"; printf 'FRIGATE_MQTT_USER=%s\nFRIGATE_MQTT_PASSWORD=%s\n' "$u" "$p"; } > "$ENVF"
rm -f "$tmp"; chmod 600 "$ENVF"
echo "  saved to configs/frigate/.env (gitignored). MQTT is already enabled in config.yaml."

cat <<'EOF'

Deploy (NUC-2):
  cd ~/home-server && git pull && ./configs/lxc/frigate.sh && ./configs/frigate/verify-frigate.sh

Then in HA: HACS → install the Frigate integration → Add Integration → Frigate →
URL http://frigate-lxc.home.alexjenkinson.com:8971.
EOF
