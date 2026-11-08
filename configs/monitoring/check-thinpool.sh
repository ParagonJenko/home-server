#!/usr/bin/env bash
# check-thinpool.sh — export LVM-thin DATA + METADATA usage to the node_exporter
# textfile collector (node_exporter's filesystem collector can't see LVM-internal
# metadata). Cron every 15 min on each NUC. [R8]
# The textfile path here MUST match node_exporter's --collector.textfile.directory.
set -euo pipefail

OUT="/var/lib/node_exporter/textfile_collector/thinpool.prom"
TMP="${OUT}.$$"
{
  lvs --noheadings --units b --nosuffix \
      -o lv_name,data_percent,metadata_percent pve/data 2>/dev/null \
  | awk '{printf "lvm_thinpool_data_percent %s\nlvm_thinpool_metadata_percent %s\n", $2, $3}'
} > "$TMP"
mv "$TMP" "$OUT"
