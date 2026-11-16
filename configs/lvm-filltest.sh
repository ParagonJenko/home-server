#!/usr/bin/env bash
# lvm-filltest.sh — B5: prove a FULL container LV goes read-only without taking the
# host down, and show the local-lvm ceiling sum. [R9 R6]
# Creates a throwaway 5G thin LV, fills it, confirms writes refuse while the host root
# stays writable, then removes it. The ceiling sum is informational — there are no
# container LVs yet at B5, so re-run it after Stage G to check the real total.
source "$(dirname "$0")/lib/common.sh"
set +e                       # common.sh sets -e; the fill is meant to hit ENOSPC
need_root
PASS=0; FAIL=0
yes_() { ok   "  PASS  $*"; PASS=$((PASS + 1)); }
no_()  { warn "  FAIL  $*"; FAIL=$((FAIL + 1)); }

VG=pve; POOL=data; LV=b5filltest; MP=/mnt/b5ft
cleanup() { umount "$MP" >/dev/null 2>&1; lvremove -y "${VG}/${LV}" >/dev/null 2>&1; rmdir "$MP" >/dev/null 2>&1; }
trap cleanup EXIT

say "1/2  fill a throwaway 5G LV; the host must survive"
if ! lvcreate -V 5G --thinpool "${VG}/${POOL}" -n "$LV" "$VG" >/dev/null 2>&1; then
  no_ "create throwaway thin LV (is ${VG}/${POOL} present?)"
else
  mkfs.ext4 -q "/dev/${VG}/${LV}" >/dev/null 2>&1
  mkdir -p "$MP"; mount "/dev/${VG}/${LV}" "$MP"
  cat /dev/zero > "${MP}/blob" 2>/dev/null          # fill to ENOSPC (expected)
  if ! dd if=/dev/zero of="${MP}/blob2" bs=1M count=1 >/dev/null 2>&1; then
    yes_ "full LV refuses further writes (ENOSPC, not a crash)"
  else
    no_ "LV accepted a write while full"
  fi
  if echo ok > /root/.b5-alive 2>/dev/null; then rm -f /root/.b5-alive; yes_ "host root still writable — host survived a full container LV"
  else no_ "host root not writable"; fi
fi
# remove the throwaway BEFORE the ceiling sum so it isn't counted (trap is the fallback)
umount "$MP" >/dev/null 2>&1; lvremove -y "${VG}/${LV}" >/dev/null 2>&1

say "2/2  ceiling sum (informational — re-run after Stage G, when the container LVs exist)"
lvs --units g -o lv_name,lv_size "$VG" 2>/dev/null
poolsz=$(lvs --noheadings --units g -o lv_size "${VG}/${POOL}" 2>/dev/null | tr -dc '0-9.')
sum=$(lvs --noheadings --units g -o lv_attr,lv_size "$VG" 2>/dev/null | awk '$1 ~ /^V/ {s+=$2} END{printf "%.1f", s+0}')
warn "  thin pool data = ${poolsz}G ; sum of thin-volume caps = ${sum}G — this sum must stay under ${poolsz}G (minus ~10% headroom) once every container exists (R6)."

echo
if [ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]; then
  ok   "================  B5 PASS (R9) — full LV degraded gracefully  ================"
  ok   "Record it in storage.md (and re-check the ceiling sum after Stage G)."
  exit 0
else
  warn "================  B5 FAIL  ================"
  exit 1
fi
