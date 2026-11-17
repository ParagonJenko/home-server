#!/usr/bin/env bash
# find-cameras.sh — discover cameras on the LAN by their open RTSP port (:554) and print
# IP + MAC, so you can (a) fill the MAC column for the cam-* rows in network.md and
# (b) set the four DHCP reservations (.30–.33). Run from any box on the LAN (the Pi is fine).
# Uses nmap if present (also resolves MAC), otherwise a bash /dev/tcp fallback + the ARP table.
set -euo pipefail
PREFIX="${1:-192.168.1}"     # first three octets; pass another to scan a different /24
PORT=554

echo "Scanning ${PREFIX}.0/24 for RTSP (:${PORT}) — cameras expose this port..."
echo

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT

if command -v nmap >/dev/null 2>&1; then
  # -sn primes ARP (MAC) as root; -p554 --open finds the RTSP hosts.
  nmap -n -p "$PORT" --open "${PREFIX}.0/24" -oG - 2>/dev/null \
    | awk '/Ports:/ && /open/ {print $2}' > "$tmp"
else
  echo "(nmap not installed — using a slower bash probe; 'apt install nmap' for MAC vendor too)"
  for i in $(seq 1 254); do
    ip="${PREFIX}.${i}"
    ( timeout 1 bash -c "exec 3<>/dev/tcp/${ip}/${PORT}" 2>/dev/null && echo "$ip" >> "$tmp" ) &
  done
  wait
fi

if [ ! -s "$tmp" ]; then
  echo "No hosts answering on :${PORT}. Cameras may have RTSP disabled, be on another VLAN,"
  echo "or be asleep. Enable local RTSP in the Eufy app first (see runbooks/cameras.md)."
  exit 0
fi

printf '%-16s  %-18s  %s\n' "IP" "MAC" "(match each to a room, then reserve .30–.33)"
printf '%-16s  %-18s  %s\n' "----------------" "------------------" ""
while read -r ip; do
  [ -n "$ip" ] || continue
  ping -c1 -W1 "$ip" >/dev/null 2>&1 || true        # prime the ARP cache
  mac="$(ip neigh show "$ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="lladdr"){print $(i+1); exit}}')"
  printf '%-16s  %-18s\n' "$ip" "${mac:-unknown (ping it from this box first)}"
done < <(sort -t. -k4 -n "$tmp" | uniq)

echo
echo "Next: set a DHCP reservation per MAC (.30 living-room, .31 kitchen, .32 bedroom, .33 basement),"
echo "write the MACs into network.md, then: python3 configs/pi/adguard-rewrites.py --apply"
