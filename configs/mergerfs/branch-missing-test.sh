#!/usr/bin/env bash
# branch-missing-test.sh — B4: prove the pool REFUSES to mount when a branch is
# missing, instead of silently unioning from the host SSD. [R9]
# Masks a branch's mount unit to simulate a gone disk. The raw systemd error that
# normally prints ("Failed to start … is masked") is the EXPECTED result — this
# script hides it and prints a clear PASS/FAIL so it can't be mistaken for a fault.
source "$(dirname "$0")/../lib/common.sh"
set +e                      # common.sh sets -e; we deliberately expect a failure here
need_root

POOL="${1:-/mnt/media}"
POOL_UNIT="$(systemd-escape -p --suffix=mount "$POOL")"
BRANCH_DIR="/mnt/pool/disk1"
BRANCH_UNIT="$(systemd-escape -p --suffix=mount "$BRANCH_DIR")"

# Always put things back, even on Ctrl-C or an unexpected error.
restore() { systemctl unmask "$BRANCH_UNIT" >/dev/null 2>&1; systemctl daemon-reload; mount -a >/dev/null 2>&1; }
trap restore EXIT

say "1/3  the pool must require its branches"
reqs="$(systemctl show -p Requires "$POOL_UNIT" | tr ' ' '\n' | grep -c '^mnt-pool-disk')"
if [ "$reqs" -ge 2 ]; then
  ok "  OK — both branch mounts are required by ${POOL_UNIT}"
else
  warn "  !! ${POOL_UNIT} does not require its branches — the x-systemd.requires= lines are missing from /etc/fstab (configs/mergerfs/fstab-snippet)"
fi

say "2/3  simulate a missing branch and try to mount the pool"
umount "$POOL" >/dev/null 2>&1
if findmnt -no TARGET "$POOL" >/dev/null 2>&1; then
  warn "  !! ${POOL} is busy and won't unmount — stop whatever is using it, then re-run."; exit 1
fi
systemctl stop "$BRANCH_UNIT" >/dev/null 2>&1
systemctl mask "$BRANCH_UNIT" >/dev/null 2>&1
systemctl start "$POOL_UNIT" >/dev/null 2>&1          # EXPECTED to fail (branch masked)
started=$?

if [ "$started" -ne 0 ] && ! findmnt -no TARGET "$POOL" >/dev/null 2>&1; then
  ok "  PASS — the pool refused to mount without its branch. (The masked-unit error is the point.)"
  result=0
else
  warn "  FAIL — the pool mounted with a branch missing; it would silently run off the host SSD. Check x-systemd.requires= in /etc/fstab."
  result=1
fi

say "3/3  restore"
restore
if findmnt -no TARGET "$POOL" >/dev/null 2>&1; then ok "  pool back — ${POOL} mounted"; else warn "  !! pool not back — run: mount -a"; fi

echo
if [ "${result:-1}" -eq 0 ]; then
  ok "================  B4 PASS (R9)  ================"
  ok "The pool fails loud when a disk is gone. Record it in storage.md."
else
  warn "================  B4 FAIL  ================"
  warn "Do not build containers on this pool until it refuses to mount without a branch."
fi
exit "${result:-1}"
