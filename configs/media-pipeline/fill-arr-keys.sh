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

get_key() {  # get_key <service> -> ApiKey from the config.xml on the host bind-mount
  # /opt/<service>/config is bind-mounted into the container as /config, so the file
  # is right here on the LXC filesystem — no need to guess the compose container name.
  grep -oP '(?<=<ApiKey>)[^<]+' "/opt/$1/config/config.xml" 2>/dev/null | head -1 || true
}

fail=0
for pair in "sonarr:SONARR_API_KEY" "radarr:RADARR_API_KEY" "prowlarr:PROWLARR_API_KEY"; do
  app="${pair%%:*}"; var="${pair##*:}"
  key="$(get_key "$app")"
  if [ -n "$key" ]; then
    upsert "$var" "$key"
    echo "${G}OK${Z}   ${var} <- /opt/${app}/config/config.xml"
  else
    echo "${R}MISS${Z} ${app}: no ApiKey in /opt/${app}/config/config.xml — booted once yet?"
    fail=1
  fi
done

# qBittorrent password — it lives in no config file (you set it in the WebUI), so prompt
# for it here. Only ask if it's not already set and we have a terminal to read from.
cur_pass="$(sed -n 's/^QBIT_PASS=//p' "$ENV_FILE" 2>/dev/null | head -1)"
if [ -z "$cur_pass" ]; then
  qp=""
  if { exec 3</dev/tty; } 2>/dev/null; then        # a real terminal, even if stdin is a pipe
    echo; read -rsp "qBittorrent password for user 'admin' (blank to skip): " qp <&3; echo
    exec 3<&-
  elif [ -t 0 ]; then
    echo; read -rsp "qBittorrent password for user 'admin' (blank to skip): " qp; echo
  else
    echo "${Y}NOTE${Z} QBIT_PASS is empty and no terminal to prompt — set it in ${ENV_FILE} by hand,"
    echo "     or re-run this script on its own line (not pasted with others)."
  fi
  if [ -n "$qp" ]; then upsert QBIT_PASS "$qp"; echo "${G}OK${Z}   QBIT_PASS set"; fi
fi

echo
if [ "$fail" = 0 ]; then
  echo "${G}API keys written to ${ENV_FILE}.${Z}"
  [ -z "$(sed -n 's/^QBIT_PASS=//p' "$ENV_FILE" | head -1)" ] \
    && echo "${Y}QBIT_PASS still empty${Z} — arr-setup can't log into qBittorrent until it's set."
  exit 0
else
  echo "${Y}Some API keys missing.${Z} Make sure the core apps are running (docker ps) and have"
  echo "booted once (they write config.xml a few seconds in), then re-run."
  exit 1
fi
