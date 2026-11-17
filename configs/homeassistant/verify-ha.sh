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
    target="$ip"; echo "${Y}note${Z} ${NAME} doesn't resolve from THIS host (its resolver is still install-time DNS until H3) — testing the agent IP ${ip}. Clients using the Pi resolve the name fine."
  else
    echo "${Y}note${Z} ${NAME} doesn't resolve and no agent IP — skipping HTTP check"
  fi
fi
if [ "$target" != "$NAME" ] || getent hosts "$NAME" >/dev/null 2>&1; then
  # HA's port isn't fixed: default is 8123, but a restored config can use 80. Try both.
  # HAOS can also be slow after a (re)boot, so retry. -L follows the onboarding redirect.
  hacode=000; haport=
  for _ in 1 2 3 4 5; do
    for p in 8123 80; do
      c="$(curl -sL -o /dev/null -w '%{http_code}' --max-time 6 "http://${target}:${p}/" 2>/dev/null)"
      case "$c" in 200|301|302|303|307|308|401|403) hacode="$c"; haport="$p"; break 2;; esac
    done
    sleep 3
  done
  if [ -n "$haport" ]; then
    pass "Home Assistant answers on :${haport} (HTTP ${hacode})"
  else
    fail "Home Assistant not answering on :8123 or :80 after retries (still booting, or not listening)"
  fi
fi

# NOTE: backup coverage (is VM 910 in the PBS job?) is an R4 check that belongs with
# the backup stage — it's verified there, after PBS and the job exist, not here.

echo
if [ "$fails" = 0 ]; then
  echo "${G}ALL CHECKS PASSED — Home Assistant is up and auto-starts.${Z}"; exit 0
else
  echo "${R}${fails} check(s) failed${Z} — inspect the failing item above."; exit 1
fi
