#!/usr/bin/env bash
# smartmon.sh — export SMART health/temperature to the node_exporter textfile
# collector. Cron on each NUC. [R24]
# NOTE: USB and DAS disks usually need `-d sat` (sometimes `-d scsi`) — smartctl
# can't read them through the bridge otherwise. Test each: smartctl -a -d sat /dev/...
# The Pi microSD exposes no SMART (watch /sys/block/mmcblk0/device/life_time instead).
set -euo pipefail

OUT="/var/lib/node_exporter/textfile_collector/smartmon.prom"
TMP="${OUT}.$$"
: > "$TMP"
for dev in /dev/sd? /dev/nvme?n1; do
  [[ -e "$dev" ]] || continue
  # TODO: pick the right -d flag per device; emit smartmon_device_smart_healthy,
  #       smartmon_temperature_celsius, smartmon_... from `smartctl -a -j`.
  :
done
mv "$TMP" "$OUT"
echo "smartmon: implement per-device scrape (see header note on -d sat)."
