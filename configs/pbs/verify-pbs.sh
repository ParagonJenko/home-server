#!/usr/bin/env bash
# verify-pbs.sh — check the PBS VM (900) on NUC-2 (G4). Runs on the NUC-2 host.
# Green PASS / red FAIL; changes nothing.
#   ./configs/pbs/verify-pbs.sh
set -uo pipefail
VMID=900
PBS_IP="192.168.1.5"           # static, set at install (R13 — PBS writes its own address)
G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; Z=$'\e[0m'
fails=0
pass(){ echo "${G}PASS${Z} $*"; }
fail(){ echo "${R}FAIL${Z} $*"; fails=$((fails+1)); }
warn(){ echo "${Y}WARN${Z} $*"; }

echo "== VM =="
if ! qm status "$VMID" >/dev/null 2>&1; then
  fail "VM ${VMID} doesn't exist — run pbs-vm.sh"; echo; exit 1
fi
qm status "$VMID" 2>/dev/null | grep -q running && pass "VM ${VMID} running" || fail "VM ${VMID} not running"
qm config "$VMID" 2>/dev/null | grep -q '^onboot: 1' && pass "onboot=1" || warn "onboot not set — PBS won't auto-start"

echo "== datastore disk passthrough (R3) =="
scsi1="$(qm config "$VMID" 2>/dev/null | grep '^scsi1:')"
if [ -n "$scsi1" ]; then
  echo "$scsi1" | grep -q 'by-id/' && pass "datastore disk attached by-id (follows the disk, R9)" || warn "scsi1 isn't a by-id path — ${scsi1#scsi1: }"
  echo "$scsi1" | grep -q 'backup=0' && pass "datastore disk has backup=0 (never swept into vzdump, R3)" || fail "scsi1 missing backup=0 — the 2TB disk could get backed up into its own datastore"
else
  fail "no scsi1 on VM ${VMID} — the USB HDD isn't attached"
fi

echo "== boot order =="
boot="$(qm config "$VMID" 2>/dev/null | grep '^boot:')"
if echo "$boot" | grep -q 'ide2'; then
  warn "boot still includes the installer ISO (ide2) — run ./configs/pbs/pbs-finalize.sh boot-switch after install, or every reboot re-enters the installer"
else
  pass "boots from the system disk, not the installer ISO"
fi

echo "== PBS web UI =="
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${PBS_IP}:8007/" 2>/dev/null)"
case "$code" in
  200|401) pass "PBS answers on ${PBS_IP}:8007 (HTTP ${code})";;
  000|"") fail "no response on ${PBS_IP}:8007 — PBS still installing, or wrong IP (expected ${PBS_IP})";;
  *) warn "PBS :8007 returned HTTP ${code}";;
esac

echo
if [ "$fails" = 0 ]; then
  echo "${G}ALL CHECKS PASSED — PBS VM up, datastore disk passed through (backup=0), UI answering.${Z}"
  echo "Next: point the NUCs' backups at it (G5), then prove a restore (G6)."; exit 0
else
  echo "${R}${fails} check(s) failed${Z} — inspect the failing item above."; exit 1
fi
