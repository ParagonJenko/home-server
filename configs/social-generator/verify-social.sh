#!/usr/bin/env bash
# verify-social.sh — read-only health check for social-generator in LXC 250. Runs INSIDE
# the container. Green PASS / red FAIL; changes nothing.
#   pct exec 250 -- bash /opt/social-generator/verify-social.sh
set -uo pipefail
APP=/opt/social-generator
PORT="$(. $APP/deploy/.env 2>/dev/null; echo "${REVIEW_PORT:-8087}")"
G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; Z=$'\e[0m'
fails=0
pass() { echo "${G}PASS${Z} $*"; }
fail() { echo "${R}FAIL${Z} $*"; fails=$((fails + 1)); }
warn() { echo "${Y}WARN${Z} $*"; }

echo "== containers =="
for svc in runner web; do
  state="$(cd $APP/deploy && docker compose ps --format '{{.State}}' "$svc" 2>/dev/null | head -1)"
  [ "$state" = running ] && pass "$svc running" || fail "$svc is '${state:-absent}' — docker compose logs $svc"
done

echo "== review page =="
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://localhost:${PORT}/")"
case "$code" in
  200) pass "review page answers on :${PORT}";;
  403|404) warn "review page :${PORT} gave HTTP ${code} — no pass has finished yet (no index.html)";;
  *) fail "review page :${PORT} returned HTTP ${code:-none}";;
esac

echo "== last pass =="
st="$(curl -s --max-time 10 "http://localhost:${PORT}/status.json")"
if [ -z "$st" ]; then warn "no status.json yet — first pass still running?"
elif echo "$st" | grep -q '"ok": *true'; then pass "last pass ok"
else fail "last pass failed — docker compose logs runner | grep FAILED"; fi

echo
if [ "$fails" = 0 ]; then echo "${G}CORE CHECKS PASSED${Z}"; exit 0
else echo "${R}${fails} check(s) failed${Z}"; exit 1; fi
