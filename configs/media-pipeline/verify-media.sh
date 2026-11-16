#!/usr/bin/env bash
# verify-media.sh — read-only health check for the whole media-pipeline stage. Runs
# INSIDE LXC 210; confirms the stack is up and arr-setup's wiring is actually in place.
# Green PASS / red FAIL per check; exits non-zero if anything failed. Changes nothing.
#   pct exec 210 -- bash /opt/media-pipeline/verify-media.sh
set -uo pipefail
cd /opt/media-pipeline
G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; Z=$'\e[0m'
fails=0
pass() { echo "${G}PASS${Z} $*"; }
fail() { echo "${R}FAIL${Z} $*"; fails=$((fails + 1)); }

# load .env (API keys + qBit creds)
set -a; [ -f .env ] && . ./.env; set +a
SK="${SONARR_API_KEY:-}"; RK="${RADARR_API_KEY:-}"; PK="${PROWLARR_API_KEY:-}"
aget() { curl -s --max-time 10 -H "X-Api-Key: $2" "http://localhost:$1$3"; }   # aget PORT KEY PATH

echo "== containers =="
for s in qbittorrent sonarr radarr bazarr prowlarr flaresolverr recyclarr decluttarr qbit_manage; do
  st="$(docker compose ps "$s" --format '{{.State}}' 2>/dev/null | head -1)"
  [ "$st" = running ] && pass "$s running" || fail "$s not running (state: ${st:-none})"
done

echo "== qBittorrent =="
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  --data-urlencode "username=${QBIT_USER:-admin}" --data-urlencode "password=${QBIT_PASS:-}" \
  -H "Referer: http://localhost:8080" http://localhost:8080/api/v2/auth/login)"
case "$code" in 200 | 204) pass "WebUI login (HTTP $code)";; *) fail "WebUI login (HTTP ${code:-none})";; esac

echo "== Sonarr =="
if [ -n "$SK" ]; then
  aget 8989 "$SK" /api/v3/rootfolder    | grep -q '/data/library/tv' && pass "root folder /data/library/tv" || fail "root folder missing"
  aget 8989 "$SK" /api/v3/downloadclient | grep -qi qbittorrent       && pass "qBittorrent download client" || fail "qBittorrent download client missing"
  aget 8989 "$SK" /api/v3/config/host   | grep -Eqi 'authenticationmethod"[[:space:]]*:[[:space:]]*"forms"' && pass "forms auth set" || fail "auth not set"
else fail "SONARR_API_KEY missing in .env"; fi

echo "== Radarr =="
if [ -n "$RK" ]; then
  aget 7878 "$RK" /api/v3/rootfolder    | grep -q '/data/library/movies' && pass "root folder /data/library/movies" || fail "root folder missing"
  aget 7878 "$RK" /api/v3/downloadclient | grep -qi qbittorrent           && pass "qBittorrent download client" || fail "qBittorrent download client missing"
  aget 7878 "$RK" /api/v3/config/host   | grep -Eqi 'authenticationmethod"[[:space:]]*:[[:space:]]*"forms"' && pass "forms auth set" || fail "auth not set"
else fail "RADARR_API_KEY missing in .env"; fi

echo "== Prowlarr =="
if [ -n "$PK" ]; then
  aget 9696 "$PK" /api/v1/indexerProxy | grep -qi flaresolverr && pass "FlareSolverr proxy" || fail "FlareSolverr proxy missing"
  aget 9696 "$PK" /api/v1/tag          | grep -qi flaresolverr && pass "'flaresolverr' tag"   || fail "'flaresolverr' tag missing"
  apps="$(aget 9696 "$PK" /api/v1/applications)"
  echo "$apps" | grep -qi sonarr && echo "$apps" | grep -qi radarr && pass "apps linked (Sonarr + Radarr)" || fail "apps not linked"
  aget 9696 "$PK" /api/v1/config/host | grep -Eqi 'authenticationmethod"[[:space:]]*:[[:space:]]*"forms"' && pass "forms auth set" || fail "auth not set"
else fail "PROWLARR_API_KEY missing in .env"; fi

echo "== Bazarr =="
bz=/opt/bazarr/config/config/config.yaml
if [ -f "$bz" ]; then
  grep -Eqi 'use_sonarr:[[:space:]]*true' "$bz" && grep -Eqi 'use_radarr:[[:space:]]*true' "$bz" \
    && pass "connected to Sonarr + Radarr" || fail "not connected (use_sonarr/use_radarr not true)"
else fail "Bazarr config.yaml not found — booted once?"; fi

echo "== hardlinks (R6) =="
t=/data/torrents/.hltest; l=/data/library/.hltest
rm -f "$t" "$l" 2>/dev/null
if touch "$t" 2>/dev/null && ln "$t" "$l" 2>/dev/null; then
  pass "hardlink /data/torrents -> /data/library (imports link, don't copy)"
else
  fail "hardlink FAILED — torrents and library on different branches; imports would COPY"
fi
rm -f "$t" "$l" 2>/dev/null

echo
if [ "$fails" = 0 ]; then
  echo "${G}ALL CHECKS PASSED — the media pipeline is wired and healthy.${Z}"; exit 0
else
  echo "${R}${fails} check(s) failed${Z} — re-run arr-setup.py --apply, or inspect the failing service above."; exit 1
fi
