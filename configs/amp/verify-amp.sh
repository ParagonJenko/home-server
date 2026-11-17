#!/usr/bin/env bash
# verify-amp.sh — read-only health check for AMP (CubeCoders) in LXC 230. AMP is
# vendor-managed and version-fluid, so this checks the essentials only. Runs INSIDE
# the container. Green PASS / red FAIL; changes nothing.
#   pct exec 230 -- bash /opt/amp/verify-amp.sh
set -uo pipefail
PORT="${AMP_PORT:-8080}"     # ADS web UI default
G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; Z=$'\e[0m'
fails=0
pass() { echo "${G}PASS${Z} $*"; }
fail() { echo "${R}FAIL${Z} $*"; fails=$((fails + 1)); }
warn() { echo "${Y}WARN${Z} $*"; }

echo "== install =="
id amp >/dev/null 2>&1 && pass "amp system user exists" || fail "no 'amp' user — installer didn't finish"
if command -v ampinstmgr >/dev/null 2>&1; then
  pass "ampinstmgr present ($(ampinstmgr --version 2>/dev/null | head -1))"
else
  fail "ampinstmgr not found — run CubeCoders' installer (getamp.sh)"
fi

echo "== instances =="
# ampinstmgr runs as the amp user; StatusAll lists every instance and its state.
out="$(runuser -l amp -c 'ampinstmgr StatusAll' 2>/dev/null || ampinstmgr StatusAll 2>/dev/null)"
if [ -n "$out" ]; then
  if echo "$out" | grep -qiE 'running|ready'; then pass "at least one AMP instance running"
  else warn "ampinstmgr listed instances but none report running:"; echo "$out" | sed 's/^/    /'; fi
else
  warn "couldn't read instance status (ampinstmgr StatusAll gave nothing) — check manually"
fi

echo "== ADS web UI =="
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://localhost:${PORT}/" 2>/dev/null)"
case "$code" in
  200|301|302) pass "ADS web UI answers on :${PORT} (HTTP ${code})";;
  401|403) pass "ADS web UI answers on :${PORT} (HTTP ${code} — login page)";;
  *) fail "ADS web UI on :${PORT} returned HTTP ${code:-none} — still starting, or wrong port?";;
esac

echo
if [ "$fails" = 0 ]; then
  echo "${G}CORE CHECKS PASSED — AMP is installed and its panel is answering.${Z}"; exit 0
else
  echo "${R}${fails} check(s) failed${Z} — inspect the failing item above."; exit 1
fi
