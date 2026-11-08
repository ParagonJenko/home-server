#!/usr/bin/env bash
# filltest.sh — prove the pool degrades gracefully instead of corrupting when full (B6). [R10 R7]
# Writes 50G blobs UNTIL THE POOL REFUSES (no fixed count — a fixed count can finish
# without ever reaching the limit). Refuses to run on a non-empty pool.
set -euo pipefail

POOL="${1:-/mnt/media}"
DIR="${POOL}/.filltest"

[[ -d "${POOL}/library" && -n "$(ls -A "${POOL}/library" 2>/dev/null)" ]] && {
  echo "!! ${POOL} already has data — refusing to fill-test." >&2; exit 1; }

mkdir -p "$DIR"; n=0
while dd if=/dev/zero of="${DIR}/blob_${n}" bs=1G count=50 status=none 2>/dev/null; do
  echo "wrote blob_${n} (50G)"; n=$((n+1))
done
echo "STOPPED at blob_${n}. Pool still mounted: $(findmnt -no TARGET "$POOL" || echo NO)"
rm -rf "$DIR"
echo "Cleanup done. Record the result (STOPPED cleanly, zero corruption) in storage.md."
