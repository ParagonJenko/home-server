#!/usr/bin/env bash
# smartmon.sh — export SMART health / temperature / readability to the node_exporter
# textfile collector. Cron on each NUC (and the Pi, for any NVMe/SATA it has). [R24]
#
# USB/DAS disks need the right -d flag (sat, sat,12, scsi, usbjmicron, ...) or smartctl
# can't read them through the bridge. This seeds the flag from `smartctl --scan-open`
# (which recommends a -d per device) and falls back to a candidate list.
#
# CRITICAL DESIGN POINT: an UNREADABLE disk is reported with smartmon_device_smart_readable=0
# and emits NO health series — so "smartctl can't read this bridge" (a flag problem) can never
# masquerade as smartmon_device_smart_healthy=0 ("disk FAILED, replace it"). The two have very
# different urgency and were conflated before, paging critical for healthy-but-unreadable disks.
#
# The Pi microSD exposes no SMART (watch /sys/block/mmcblk0/device/life_time instead).
# Needs: smartmontools + jq.
set -euo pipefail

OUT="/var/lib/node_exporter/textfile_collector/smartmon.prom"
TMP="${OUT}.$$"
mkdir -p "$(dirname "$OUT")"
: > "$TMP"
emit() { printf '%s\n' "$1" >> "$TMP"; }

emit "# HELP smartmon_device_smart_healthy SMART overall health (1=passed, 0=FAILED). Present only for readable disks."
emit "# TYPE smartmon_device_smart_healthy gauge"
emit "# HELP smartmon_device_smart_readable smartctl could read SMART (1=yes, 0=no -d flag worked)."
emit "# TYPE smartmon_device_smart_readable gauge"
emit "# HELP smartmon_temperature_celsius Drive temperature in Celsius."
emit "# TYPE smartmon_temperature_celsius gauge"

# Seed each device's recommended -d from `smartctl --scan-open` (lines like "/dev/sda -d sat # ...").
declare -A HINT
while read -r sdev dflag dtype _rest; do
  [ "${dflag:-}" = "-d" ] && HINT["$sdev"]="$dtype"
done < <(smartctl --scan-open 2>/dev/null || true)

# Echo "<dtype>\t<json>" and exit 0 on the first flag that yields a SMART status; exit 1 if none do.
read_dev() {
  local dev="$1" d j
  for d in "${HINT[$dev]:-}" "" sat "sat,12" "sat,16" scsi usbjmicron usbsunplus usbprolific nvme; do
    j="$(smartctl -a -j ${d:+-d $d} "$dev" 2>/dev/null)" || true
    if printf '%s' "$j" | jq -e '.smart_status' >/dev/null 2>&1; then
      printf '%s\t%s' "${d:-auto}" "$j"; return 0
    fi
  done
  return 1
}

scan() {
  local dev="$1" base out dtype j healthy temp
  base="$(basename "$dev")"
  if out="$(read_dev "$dev")"; then
    dtype="${out%%$'\t'*}"; j="${out#*$'\t'}"
    healthy="$(printf '%s' "$j" | jq -r 'if .smart_status.passed then 1 else 0 end')"
    temp="$(printf '%s' "$j" | jq -r '.temperature.current // empty')"
    emit "smartmon_device_smart_readable{device=\"${base}\",dtype=\"${dtype}\"} 1"
    emit "smartmon_device_smart_healthy{device=\"${base}\",dtype=\"${dtype}\"} ${healthy}"
    [ -n "$temp" ] && emit "smartmon_temperature_celsius{device=\"${base}\",dtype=\"${dtype}\"} ${temp}"
  else
    # Unreadable through every flag tried — surface as readable=0, NEVER as health=0.
    emit "smartmon_device_smart_readable{device=\"${base}\",dtype=\"unreadable\"} 0"
  fi
}

for dev in /dev/sd? /dev/nvme?n1; do
  [ -e "$dev" ] || continue
  scan "$dev"
done
emit "smartmon_last_collect_timestamp_seconds $(date +%s)"
mv "$TMP" "$OUT"
echo "smartmon: wrote $OUT"
