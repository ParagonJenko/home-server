#!/usr/bin/env bash
# verify-restore.sh — prove a PBS backup actually restores (G6, R4/R12). Run on the NUC that
# holds the guest. Restores the latest backup of a guest into a THROWAWAY CT, boots it, checks
# it runs, then destroys it. Changes nothing permanent — the live guest is never touched.
# Green PASS / red FAIL.
#   ./configs/pbs/verify-restore.sh [GUEST]        # default GUEST=210 (media-pipeline)
#   PBS_STORE=pbs-backup TARGET_STORAGE=local-lvm ./configs/pbs/verify-restore.sh 220
set -uo pipefail
GUEST="${1:-210}"
STORE="${PBS_STORE:-pbs-backup}"
TARGET_STORAGE="${TARGET_STORAGE:-local-lvm}"
CLONE="8${GUEST}"                      # 210 -> 8210, a scratch ID that must be free
G=$'\e[1;92m'; R=$'\e[1;91m'; Y=$'\e[1;93m'; Z=$'\e[0m'
fails=0
pass(){ echo "${G}PASS${Z} $*"; }
fail(){ echo "${R}FAIL${Z} $*"; fails=$((fails+1)); }

cleanup(){               # always tear the throwaway down, even on failure
  if pct status "$CLONE" >/dev/null 2>&1; then
    echo "cleanup: removing throwaway CT ${CLONE}"
    pct stop "$CLONE" >/dev/null 2>&1
    pct destroy "$CLONE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

[ "$(id -u)" = 0 ] || { fail "run as root (sudo)"; exit 1; }

# The scratch ID must be free — never reuse a live VMID.
if pct status "$CLONE" >/dev/null 2>&1 || qm status "$CLONE" >/dev/null 2>&1; then
  fail "VMID ${CLONE} already exists — this script needs it as scratch; clear it first"; trap - EXIT; exit 1
fi

echo "== find a backup of CT ${GUEST} on ${STORE} =="
VOLID="$(pvesm list "$STORE" 2>/dev/null | awk -v g="ct/${GUEST}/" 'index($1,g){print $1}' | tail -1)"
if [ -z "$VOLID" ]; then
  fail "no ct/${GUEST} backup on ${STORE} — take one first:  vzdump ${GUEST} --storage ${STORE} --mode snapshot"
  trap - EXIT; exit 1
fi
pass "found ${VOLID}"

echo "== restore -> throwaway CT ${CLONE} =="
if pct restore "$CLONE" "$VOLID" --storage "$TARGET_STORAGE" >/dev/null 2>&1; then
  pass "restored into CT ${CLONE} (decryption OK)"
else
  fail "pct restore failed — wrong/absent encryption key, or ${TARGET_STORAGE} full? Re-run by hand to see the error"
  exit 1
fi

# Keep the clone from fighting the live guest: DHCP, and drop any bind mount.
pct set "$CLONE" --net0 name=eth0,bridge=vmbr0,ip=dhcp >/dev/null 2>&1 || true
pct set "$CLONE" --delete mp0 >/dev/null 2>&1 || true

echo "== boot it =="
if pct start "$CLONE" >/dev/null 2>&1; then
  for _ in $(seq 1 10); do
    [ "$(pct status "$CLONE" 2>/dev/null)" = "status: running" ] && break
    sleep 1
  done
  if [ "$(pct status "$CLONE" 2>/dev/null)" = "status: running" ]; then
    pass "CT ${CLONE} restored from backup and is running"
  else
    fail "CT ${CLONE} restored but didn't reach running"
  fi
else
  fail "CT ${CLONE} restored but wouldn't start"
fi

echo
if [ "$fails" = 0 ]; then
  echo "${G}RESTORE PROVEN — ${VOLID} restored, booted, torn down.${Z}"
  echo "(Still the easy case: same box, local PBS, seconds after the backup. The real R12 bar is a"
  echo " restore from the OFFSITE copy onto different hardware — fold that into the I3 relocation test.)"
  exit 0
else
  echo "${R}${fails} check(s) failed — the backup is NOT proven restorable. Fix before trusting it (R12).${Z}"
  exit 1
fi
