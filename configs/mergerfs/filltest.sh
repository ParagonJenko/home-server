#!/usr/bin/env bash
# filltest.sh — prove the pool degrades gracefully instead of corrupting when full (B3). [R10 R7]
# Writes blobs UNTIL THE POOL REFUSES (no fixed count — a fixed count can finish without
# ever reaching the limit). Refuses to run on a pool that already holds real files.
#
#   --quick   Temporarily raise minfreespace via mergerfs' runtime control file so the pool
#             refuses after ~30G per branch (~30-60 min) instead of filling the whole pool
#             (a day+ on SMR drives, plus the wear). Proves the SAME graceful stop, then
#             restores the floor. Untested on hardware — watch the first run.
set -euo pipefail

POOL="/mnt/media"
QUICK=0
for a in "$@"; do
  case "$a" in
    --quick) QUICK=1 ;;
    /*)      POOL="$a" ;;
    *)       echo "usage: $0 [--quick] [POOL]"; exit 1 ;;
  esac
done
DIR="${POOL}/.filltest"
CTRL="${POOL}/.mergerfs"

# Refuse only if the pool holds real files — the empty torrents/ library/ scaffold
# and lost+found are directories (created by stage-b) and don't count.
if find "$POOL" -type f ! -path "${DIR}/*" -print -quit 2>/dev/null | grep -q .; then
  echo "!! ${POOL} already has files — refusing to fill-test." >&2; exit 1
fi

BLOB_GB=50
if [ "$QUICK" = 1 ]; then
  command -v setfattr >/dev/null 2>&1 || { echo "installing attr (setfattr/getfattr)"; apt-get -y install attr >/dev/null; }
  [ -e "$CTRL" ] || { echo "!! $CTRL not found — is $POOL a mergerfs mount?" >&2; exit 1; }

  ORIG="$(getfattr --only-values -n user.mergerfs.minfreespace "$CTRL" 2>/dev/null || true)"
  [ -n "$ORIG" ] || ORIG="250G"          # fall back to the configured floor
  BRANCHES="$(getfattr --only-values -n user.mergerfs.srcmounts "$CTRL" 2>/dev/null | tr ':' ' ')"
  [ -n "$BRANCHES" ] || { echo "!! could not read branches from $CTRL" >&2; exit 1; }

  MIN=""
  for b in $BRANCHES; do
    avail="$(df -B1 --output=avail "$b" 2>/dev/null | tail -1 | tr -d ' ')"
    [ -n "$avail" ] || continue
    { [ -z "$MIN" ] || [ "$avail" -lt "$MIN" ]; } && MIN="$avail"
  done
  [ -n "$MIN" ] || { echo "!! could not read branch free space" >&2; exit 1; }

  HEADROOM=$((30 * 1024 * 1024 * 1024))   # ~30G per branch before it refuses
  TARGET=$((MIN - HEADROOM))
  [ "$TARGET" -gt 0 ] || { echo "!! not enough free space for a quick test" >&2; exit 1; }

  restore() { setfattr -n user.mergerfs.minfreespace -v "$ORIG" "$CTRL" 2>/dev/null \
                && echo "restored minfreespace=$ORIG"; }
  trap 'rm -rf "$DIR"; restore' EXIT

  echo "quick: raising minfreespace to ~$((TARGET / 1024 / 1024 / 1024))G/branch so the pool refuses soon"
  setfattr -n user.mergerfs.minfreespace -v "$TARGET" "$CTRL"
  BLOB_GB=10
else
  trap 'rm -rf "$DIR"' EXIT
fi

mkdir -p "$DIR"; n=0
while dd if=/dev/zero of="${DIR}/blob_${n}" bs=1G count=${BLOB_GB} status=none 2>/dev/null; do
  echo "wrote blob_${n} (${BLOB_GB}G)"; n=$((n + 1))
done
echo "STOPPED at blob_${n} — pool still mounted: $(findmnt -no TARGET "$POOL" || echo NO)"
echo "Cleanup + (quick) floor-restore happen on exit. Record the result (STOPPED cleanly, zero corruption) in storage.md."
