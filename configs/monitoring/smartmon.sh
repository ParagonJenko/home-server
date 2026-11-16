#!/usr/bin/env bash
# smartmon.sh — export SMART health/temperature to the node_exporter textfile
# collector. Cron on each NUC. [R24]
# NOTE: USB and DAS disks usually need `-d sat` (sometimes `-d scsi`) — smartctl
# can't read them through the bridge otherwise. This script auto-detects the -d flag.
# The Pi microSD exposes no SMART (watch /sys/block/mmcblk0/device/life_time instead).
# Needs: smartmontools + jq (ENTER: apt install smartmontools jq if missing).
set -euo pipefail

OUT="/var/lib/node_exporter/textfile_collector/smartmon.prom"
TMP="${OUT}.$$"
mkdir -p "$(dirname "$OUT")"
: > "$TMP"
emit() { printf '%s\n' "$1" >> "$TMP"; }

emit "# HELP smartmon_device_smart_healthy SMART overall health (1=passed, 0=failed)"
emit "# TYPE smartmon_device_smart_healthy gauge"
emit "# HELP smartmon_temperature_celsius Drive temperature in Celsius"
emit "# TYPE smartmon_temperature_celsius gauge"

scan() {
  local dev="$1" base j healthy temp d label
  base="$(basename "$dev")"
  # Try auto, then -d sat, then -d scsi — first one that returns SMART status wins.
  for d in "" "-d sat" "-d scsi"; do
    if j="$(smartctl -a -j $d "$dev" 2>/dev/null)" \
       && printf '%s' "$j" | jq -e '.smart_status' >/dev/null 2>&1; then
      healthy="$(printf '%s' "$j" | jq -r 'if .smart_status.passed then 1 else 0 end')"
      temp="$(printf '%s' "$j" | jq -r '.temperature.current // empty')"
      label="device=\"${base}\",dtype=\"${d:-auto}\""
      emit "smartmon_device_smart_healthy{${label}} ${healthy}"
      [ -n "$temp" ] && emit "smartmon_temperature_celsius{${label}} ${temp}"
      return 0
    fi
  done
  # Couldn't read it at all — surface that as unhealthy so it alerts rather than hides.
  emit "smartmon_device_smart_healthy{device=\"${base}\",dtype=\"unreadable\"} 0"
}

for dev in /dev/sd? /dev/nvme?n1; do
  [ -e "$dev" ] || continue
  scan "$dev"
done
emit "smartmon_last_collect_timestamp_seconds $(date +%s)"
mv "$TMP" "$OUT"
echo "smartmon: wrote $OUT"
