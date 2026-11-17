#!/usr/bin/env bash
# set-network-access.sh — set Plex's "Custom server access URLs" + "LAN Networks" from code,
# so Plex is reachable over the Tailscale subnet router instead of failing to a relay (I1).
# Runs on NUC-1. Plex rewrites Preferences.xml on shutdown, so: stop -> edit -> start.
#   ./configs/plex/set-network-access.sh
#   PLEX_CONN=... PLEX_LAN=... ./configs/plex/set-network-access.sh   # override the defaults
set -euo pipefail
cd "$(dirname "$0")"
source ../lib/common.sh
need_root
CTID=220

# customConnections = the LAN address(es) the subnet route reaches (plex.tv only hands out the
#   public IP, which a tailnet client can't use). LanNetworksBandwidth = treat the LAN AND the
#   Tailscale CGNAT range (100.64.0.0/10) as local, so tailnet clients stream direct, not relayed.
CONN="${PLEX_CONN:-http://192.168.1.22:32400,http://plex-lxc.home.alexjenkinson.com:32400}"
LAN="${PLEX_LAN:-192.168.1.0/24,100.64.0.0/10}"

pct status "$CTID" 2>/dev/null | grep -q running || { warn "CT ${CTID} (plex) not running."; exit 1; }
PREFS='/opt/plex/config/Library/Application Support/Plex Media Server/Preferences.xml'
pct exec "$CTID" -- test -f "$PREFS" || { warn "Preferences.xml not found — has Plex been claimed/started yet?"; exit 1; }

say "set Plex customConnections + LanNetworksBandwidth (stop -> edit -> start)"
pct exec "$CTID" -- bash -s "$CONN" "$LAN" <<'INNER'
set -e
CONN="$1"; LAN="$2"
P="/opt/plex/config/Library/Application Support/Plex Media Server/Preferences.xml"
cd /opt/plex && docker compose stop plex >/dev/null
set_attr() {   # set_attr NAME VALUE — replace the attribute if present, else insert it
  if grep -q " $1=\"" "$P"; then
    sed -i "s| $1=\"[^\"]*\"| $1=\"$2\"|" "$P"
  else
    sed -i "s|<Preferences |<Preferences $1=\"$2\" |" "$P"
  fi
}
set_attr customConnections "$CONN"
set_attr LanNetworksBandwidth "$LAN"
cd /opt/plex && docker compose start plex >/dev/null
INNER

ok "set — customConnections=${CONN}"
ok "      LanNetworksBandwidth=${LAN}"
echo "Plex → Settings → Network will now show these; tailnet clients connect direct (no relay)."
