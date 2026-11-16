#!/usr/bin/env bash
# stage-d-adguard.sh — D3: bring up AdGuard, push the DNS rewrites from network.md,
# and point the Pi at its own resolver. Run on the Pi, FROM THE REPO (adguard-rewrites.py
# needs ../../network.md next to it). The AdGuard first-run wizard is a web step in the
# middle, so the script pauses for it. [R13 R14 R19]
#
# Note: it does NOT touch .env / the webhook — setup-pi.sh (D2) already set those up.
cd "$(dirname "$0")"
source ../lib/common.sh
set +e
need_root
FAIL=0

say "bring up AdGuard on its own"
if (cd /opt/pi-stack && docker compose up -d adguardhome >/dev/null 2>&1); then
  ok "  adguardhome container up"
else warn "  docker compose up failed"; FAIL=1; fi

PI_IP="$(hostname -I | awk '{print $1}')"
pause "AdGuard wizard — open http://${PI_IP}:3000 and:
   1. set the admin interface to PORT 8081 (Grafana owns 3000)
   2. create an admin username + password
   3. set upstream DNS to 1.1.1.1
   Press Enter when the wizard is finished."

say "push the DNS rewrites from network.md over the API (no typing 18 entries by hand)"
ask ADGUARD_USERNAME "AdGuard admin username (the one you just set in the wizard)"
read -rsp "$(printf '%s  AdGuard admin password:%s ' "$C_WARN" "$C_RST")" ADGUARD_PASS; echo
# a gitignored creds file so the scheduled --check can run non-interactively later
printf 'ADGUARD_USERNAME=%s\nADGUARD_PASSWORD=%s\n' "$ADGUARD_USERNAME" "$ADGUARD_PASS" > ./adguard.creds
chmod 600 ./adguard.creds
export ADGUARD_URL="http://127.0.0.1:8081"
./adguard-rewrites.py                                    # dry run (shows the plan)
if ./adguard-rewrites.py --apply && ./adguard-rewrites.py --check; then
  ok "  rewrites applied and verified against network.md"
else warn "  adguard-rewrites failed — check the admin creds and that the UI is on :8081"; FAIL=1; fi

say "point the Pi at its own resolver — 127.0.0.1 ONLY (upstream 1.1.1.1 lives in AdGuard)"
CON="$(nmcli -g NAME,DEVICE con show | awk -F: '$2=="eth0"{print $1; exit}')"
if nmcli con mod "$CON" ipv4.dns 127.0.0.1 && nmcli con up "$CON" >/dev/null 2>&1; then
  ok "  resolver = 127.0.0.1"
else warn "  resolver switch failed"; FAIL=1; fi

echo
if [ "$FAIL" -eq 0 ]; then
  ok "================  stage-d PASS — AdGuard + internal DNS live  ================"
  ok "Next: ./configs/verify.sh D3"
  exit 0
else
  warn "================  stage-d FAILED — see the red lines above  ================"
  exit 1
fi
