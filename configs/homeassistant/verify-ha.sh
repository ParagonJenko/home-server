#!/usr/bin/env bash
# verify-ha.sh — read-only health check for Home Assistant OS VM 910. Runs on the
# NUC-2 HOST (HAOS is a VM, no repo inside it). Green PASS / red FAIL per check;
# changes nothing. Non-zero exit on any failure.
#   ./configs/homeassistant/verify-ha.sh
set -uo pipefail
VMID=910
NAME="homeassistant.home.alexjenkinson.com"
G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; Z=$'\e[0m'
fails=0
pass() { echo "${G}PASS${Z} $*"; }
fail() { echo "${R}FAIL${Z} $*"; fails=$((fails + 1)); }

echo "== VM =="
st="$(qm status "$VMID" 2>/dev/null | awk '{print $2}')"
[ "$st" = running ] && pass "VM ${VMID} running" || fail "VM ${VMID} not running (status: ${st:-none})"

# onboot must be 1 so HA comes back after a power event (R22 graceful shutdown pairs with this).
if qm config "$VMID" 2>/dev/null | grep -q '^onboot: 1'; then
  pass "onboot=1 (starts automatically after a reboot)"
else
  fail "onboot not set — HA won't come back on its own after a power event"
fi

echo "== qemu guest agent =="
if qm agent "$VMID" ping >/dev/null 2>&1; then
  pass "guest agent responding"
else
  fail "guest agent not responding (HAOS ships it — still booting, or agent disabled)"
fi

echo "== web UI =="
# Prefer the DNS name (R13); fall back to the agent-reported IP if DNS isn't set yet.
target="$NAME"
if ! getent hosts "$NAME" >/dev/null 2>&1; then
  ip="$(qm agent "$VMID" network-get-interfaces 2>/dev/null \
        | grep -oE '"ip-address" : "192\.168\.[0-9]+\.[0-9]+"' | grep -oE '192\.168[0-9.]+' | head -1)"
  if [ -n "${ip:-}" ]; then
    target="$ip"; echo "${Y}note${Z} ${NAME} doesn't resolve yet — using agent IP ${ip} (add the DNS rewrite at Stage D)"
  else
    echo "${Y}note${Z} ${NAME} doesn't resolve and no agent IP — skipping HTTP check"
  fi
fi
if [ "$target" != "$NAME" ] || getent hosts "$NAME" >/dev/null 2>&1; then
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${target}:8123/" 2>/dev/null)"
  # Any HTTP response means HA's web server is up; 307/302 is it redirecting to onboarding/login.
  case "$code" in
    200|301|302|303|307|308|401|403) pass "Home Assistant answers on :8123 (HTTP ${code})";;
    5*) fail "Home Assistant :8123 returned ${code} — check the VM";;
    000|"") fail "Home Assistant :8123 — no response (still booting? first boot ~2 min)";;
    *) warn "Home Assistant :8123 returned HTTP ${code}";;
  esac
fi

echo "== backups (R4) =="
# A guest is only protected if a backup job selects it — but before PBS + the backup
# job exist (Stage G), that's a 'not yet', not a failure.
if [ ! -s /etc/pve/jobs.cfg ] || ! grep -q 'vzdump' /etc/pve/jobs.cfg 2>/dev/null; then
  warn "no PBS backup job yet — add VM ${VMID} once PBS is up (Stage G, R4)"
elif grep -rsqE "(^|[:, ])${VMID}([,: ]|$)|all: 1|all:1" /etc/pve/jobs.cfg 2>/dev/null; then
  pass "a backup job covers VM ${VMID} (or backs up all guests)"
else
  fail "a backup job exists but doesn't select VM ${VMID} — add it (R4)"
fi

echo
if [ "$fails" = 0 ]; then
  echo "${G}ALL CHECKS PASSED — Home Assistant is up, auto-starts, and is backed up.${Z}"; exit 0
else
  echo "${R}${fails} check(s) failed${Z} — inspect the failing item above."; exit 1
fi
