#!/usr/bin/env bash
# verify-property.sh — read-only health check for local-property-finder in LXC 260. Runs
# INSIDE the container. Green PASS / red FAIL; changes nothing.
#   pct exec 260 -- bash /opt/local-property-finder/verify-property.sh
set -uo pipefail
APP=/opt/local-property-finder
G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; Z=$'\e[0m'
fails=0
pass() { echo "${G}PASS${Z} $*"; }
fail() { echo "${R}FAIL${Z} $*"; fails=$((fails + 1)); }
warn() { echo "${Y}WARN${Z} $*"; }

echo "== config =="
[ -f "$APP/data/config.yaml" ] && pass "data/config.yaml present" || fail "no data/config.yaml — copy it in and re-run property-finder.sh"

echo "== containers =="
for svc in api scraper frontend; do
  state="$(cd $APP && docker compose ps --format '{{.State}}' "$svc" 2>/dev/null | head -1)"
  [ "$state" = running ] && pass "$svc running" || fail "$svc is '${state:-absent}' — docker compose logs $svc"
done

echo "== endpoints =="
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:3001/health)"
[ "$code" = 200 ] && pass "API /health on :3001" || fail "API /health on :3001 returned HTTP ${code:-none}"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:3000/)"
[ "$code" = 200 ] && pass "frontend on :3000" || fail "frontend on :3000 returned HTTP ${code:-none}"

echo "== data =="
if [ -f "$APP/data/properties.db" ]; then pass "properties.db exists ($(du -h "$APP/data/properties.db" | cut -f1))"
else warn "no properties.db yet — first scrape not finished?"; fi

echo
if [ "$fails" = 0 ]; then echo "${G}CORE CHECKS PASSED${Z}"; exit 0
else echo "${R}${fails} check(s) failed${Z}"; exit 1; fi
