#!/usr/bin/env bash
# fill-arr-keys.sh — after the Arrs have booted once, read each app's generated API
# key out of its config.xml and write it into .env, so arr-setup.py and recyclarr can
# use them without copy-pasting from four web UIs. Self-contained (no common.sh) because
# it runs INSIDE LXC 210, where only /opt/media-pipeline is populated:
#   pct exec 210 -- bash /opt/media-pipeline/fill-arr-keys.sh
set -euo pipefail
ENV_FILE="${1:-/opt/media-pipeline/.env}"
G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; Z=$'\e[0m'

upsert() {  # upsert KEY VALUE into ENV_FILE (replace in place, or append)
  local k="$1" v="$2"
  touch "$ENV_FILE"
  if grep -q "^${k}=" "$ENV_FILE"; then
    sed -i "s|^${k}=.*|${k}=${v}|" "$ENV_FILE"
  else
    echo "${k}=${v}" >> "$ENV_FILE"
  fi
}

get_key() {  # get_key <container> -> prints the ApiKey from its config.xml, or nothing
  docker exec "$1" cat /config/config.xml 2>/dev/null \
    | grep -oP '(?<=<ApiKey>)[^<]+' || true
}

fail=0
for pair in "sonarr:SONARR_API_KEY" "radarr:RADARR_API_KEY" "prowlarr:PROWLARR_API_KEY"; do
  app="${pair%%:*}"; var="${pair##*:}"
  key="$(get_key "$app")"
  if [ -n "$key" ]; then
    upsert "$var" "$key"
    echo "${G}OK${Z}   ${var} <- ${app}/config.xml"
  else
    echo "${R}MISS${Z} ${app}: no ApiKey yet — started and booted once? (docker logs ${app})"
    fail=1
  fi
done

echo
if [ "$fail" = 0 ]; then
  echo "${G}All three API keys written to ${ENV_FILE}.${Z}"
  echo "Only ${Y}QBIT_PASS${Z} is left by hand — the WebUI password you set for user 'admin'."
  exit 0
else
  echo "${Y}Some keys missing. Bring the core apps up, let them boot, then re-run.${Z}"
  exit 1
fi
