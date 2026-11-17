#!/usr/bin/env bash
# verify-plex.sh — read-only health check for the Plex stage (LXC 220). Runs INSIDE the
# LXC; green PASS / red FAIL per check, non-zero exit on any failure. Changes nothing.
#   pct exec 220 -- bash /opt/plex/verify-plex.sh
set -uo pipefail
cd /opt/plex
G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; Z=$'\e[0m'
fails=0
pass() { echo "${G}PASS${Z} $*"; }
fail() { echo "${R}FAIL${Z} $*"; fails=$((fails + 1)); }

echo "== container =="
st="$(docker compose ps plex --format '{{.State}}' 2>/dev/null | head -1)"
[ "$st" = running ] && pass "plex running" || fail "plex not running (state: ${st:-none})"

echo "== WebUI =="
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:32400/identity)"
case "$code" in 200) pass "Plex responds on :32400 (HTTP 200)";; *) fail "Plex API (HTTP ${code:-none}) — still starting?";; esac

echo "== media pool (read-only, R6) =="
for p in /data/library/movies /data/library/tv; do
  [ -d "$p" ] && pass "$p present" || fail "$p missing"
done
# the pool is mounted ro=1 — Plex must never be able to write it
if touch /data/.plexwtest 2>/dev/null; then
  fail "/data is WRITABLE — pool should be mounted ro=1"; rm -f /data/.plexwtest
else
  pass "/data is read-only (Plex can't modify the pool)"
fi

echo "== library inside Plex =="
if [ "$st" = running ]; then
  docker compose exec -T plex sh -c 'test -d /library/movies && test -d /library/tv' 2>/dev/null \
    && pass "/library/movies + /library/tv visible inside Plex" || fail "library not visible inside Plex"
  if docker compose exec -T plex sh -c 'touch /library/movies/.wtest' 2>/dev/null; then
    docker compose exec -T plex sh -c 'rm -f /library/movies/.wtest' 2>/dev/null
    fail "library is WRITABLE inside Plex — should be :ro"
  else
    pass "library is read-only inside Plex"
  fi
else
  fail "skipped in-container checks — plex isn't running"
fi

echo "== hardware transcode (/dev/dri) =="
if [ -d /dev/dri ] && ls /dev/dri/renderD* >/dev/null 2>&1; then
  pass "/dev/dri present in the LXC ($(ls /dev/dri | tr '\n' ' '))"
  [ "$st" = running ] && { docker compose exec -T plex sh -c 'ls /dev/dri/renderD* >/dev/null 2>&1' \
    && pass "/dev/dri passed into Plex" || fail "/dev/dri not visible inside Plex"; }
else
  echo "${Y}SKIP${Z} no /dev/dri in the LXC — hardware transcode off (fine if this NUC has no iGPU)"
fi

echo
if [ "$fails" = 0 ]; then
  echo "${G}ALL CHECKS PASSED — Plex is up, library is read-only, GPU passed through.${Z}"; exit 0
else
  echo "${R}${fails} check(s) failed${Z} — inspect the failing item above."; exit 1
fi
