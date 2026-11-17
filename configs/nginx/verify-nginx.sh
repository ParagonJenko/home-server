#!/usr/bin/env bash
# verify-nginx.sh — read-only health check for the reverse proxy + TLS (LXC 240).
# Runs INSIDE nginx LXC 240. Green PASS / red FAIL per check; changes nothing.
#   pct exec 240 -- bash /opt/nginx/verify-nginx.sh
set -uo pipefail
DOMAIN="home.alexjenkinson.com"
CRT="/etc/nginx/certs/${DOMAIN}.crt"
FRONTS="plex frigate sonarr radarr bazarr prowlarr qbittorrent"
G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; Z=$'\e[0m'
fails=0
pass() { echo "${G}PASS${Z} $*"; }
fail() { echo "${R}FAIL${Z} $*"; fails=$((fails + 1)); }
warn() { echo "${Y}WARN${Z} $*"; }

echo "== nginx =="
systemctl is-active --quiet nginx && pass "nginx running" || fail "nginx not running"
if nginx -t >/dev/null 2>&1; then pass "nginx -t config valid"; else fail "nginx -t failed — run 'nginx -t' to see why"; fi

echo "== certificate =="
if [ -f "$CRT" ]; then
  pass "cert present ($CRT)"
  if openssl x509 -in "$CRT" -noout -ext subjectAltName 2>/dev/null | grep -q "\*.${DOMAIN}"; then
    pass "cert covers *.${DOMAIN}"
  else
    fail "cert does NOT list *.${DOMAIN} in its SAN"
  fi
  if openssl x509 -in "$CRT" -checkend $((14*86400)) >/dev/null 2>&1; then
    exp="$(openssl x509 -in "$CRT" -noout -enddate 2>/dev/null | cut -d= -f2)"
    pass "cert valid > 14 days (expires ${exp})"
  else
    fail "cert expires within 14 days — check acme.sh renewal"
  fi
  issuer="$(openssl x509 -in "$CRT" -noout -issuer 2>/dev/null)"
  case "$issuer" in *"Let's Encrypt"*|*"Encrypt"*) pass "issued by Let's Encrypt";; *) warn "issuer is not Let's Encrypt: ${issuer}";; esac
else
  fail "no cert at $CRT — run enable-tls.sh"
fi

echo "== acme.sh renewal =="
if [ -f "$HOME/.acme.sh/acme.sh" ] && { crontab -l 2>/dev/null | grep -q acme.sh; }; then
  pass "acme.sh installed with a renewal cron"
else
  warn "acme.sh renewal cron not found — renewals won't be automatic"
fi

echo "== per-service (resolve + :80->:443 redirect + TLS) =="
for s in $FRONTS; do
  name="${s}.${DOMAIN}"
  if ! getent hosts "$name" >/dev/null 2>&1; then
    fail "$name does not resolve (AdGuard rewrite missing — Stage D)"; continue
  fi
  # :80 must 301 to https
  loc="$(curl -sI --max-time 8 "http://${name}/" 2>/dev/null | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r')"
  case "$loc" in https://*) :;; *) fail "$name :80 did not redirect to https (got '${loc:-none}')"; continue;; esac
  # :443 TLS handshake must verify against the system CA (not self-signed)
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://${name}/" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "$name :443 TLS failed to verify (curl exit ${rc}) — cert/trust problem"
  else
    case "$code" in
      200|301|302|401|403) pass "$name — redirect ok, valid TLS, backend answered (HTTP ${code})";;
      502|504) warn "$name — TLS ok, but backend ${code} (that service's container down?)";;
      *) warn "$name — TLS ok, HTTP ${code}";;
    esac
  fi
done

echo
if [ "$fails" = 0 ]; then
  echo "${G}ALL CHECKS PASSED — proxy up, wildcard TLS valid, every front name redirects and verifies.${Z}"; exit 0
else
  echo "${R}${fails} check(s) failed${Z} — inspect the failing item above."; exit 1
fi
