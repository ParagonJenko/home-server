#!/usr/bin/env bash
# setup-pi.sh — base the Pi (D2). Run as root. Base packages, Docker, SD-card write
# reductions, and the stack deployed into /opt. Stops short of bringing the stack UP —
# that needs your secrets (Grafana password, Discord webhook), which you fill in next.
cd "$(dirname "$0")"
source ../lib/common.sh
set +e                        # common.sh sets -e; we track failures and report at the end
need_root
FAIL=0

say "base packages"
if apt update -qq && apt -y install ca-certificates curl git >/dev/null 2>&1; then
  ok "  ca-certificates, curl, git installed"
else warn "  apt install failed"; FAIL=1; fi

say "Docker"
if command -v docker >/dev/null 2>&1; then
  ok "  already installed"
else
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1    # quiet — the installer is noisy
fi
systemctl enable --now docker >/dev/null 2>&1
if docker version >/dev/null 2>&1; then ok "  Docker running ($(docker --version | awk '{print $3}' | tr -d ,))"
else warn "  Docker not running"; FAIL=1; fi

say "SD-card write reductions (journald volatile, swap off)"
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=volatile\n' > /etc/systemd/journald.conf.d/volatile.conf
systemctl disable --now dphys-swapfile >/dev/null 2>&1 || true
systemctl restart systemd-journald >/dev/null 2>&1 || true
if [ -z "$(swapon --show 2>/dev/null)" ]; then ok "  swap off, journald volatile"
else warn "  swap still on"; FAIL=1; fi

say "deploy the stack into /opt (configs come from the repo — edit there, re-run to redeploy)"
mkdir -p /opt/pi-stack /opt/monitoring
if cp -r ./. /opt/pi-stack/ && cp -r ../monitoring/. /opt/monitoring/; then
  ok "  configs/pi -> /opt/pi-stack ; configs/monitoring -> /opt/monitoring"
else warn "  copy into /opt failed"; FAIL=1; fi

say "create the secret files from templates (chmod 600, gitignored)"
( cd /opt/pi-stack
  [ -f .env ] || cp .env.example .env 2>/dev/null
  chmod 600 .env 2>/dev/null
  [ -f alertmanager/discord-webhook-url ] || cp alertmanager/discord-webhook-url.example alertmanager/discord-webhook-url 2>/dev/null
  chmod 600 alertmanager/discord-webhook-url 2>/dev/null )
save "Fill these before D3/H1:"
save "  .env  ->  GENERATE a Grafana password:  openssl rand -base64 24   (then save it to your vault, R21)"
save "  alertmanager/discord-webhook-url  ->  PASTE the URL from Discord (Server Settings > Integrations > Webhooks)"

echo
if [ "$FAIL" -eq 0 ]; then
  ok "================  setup-pi PASS — it all worked  ================"
  ok "Next: fill the two secret files above, then D3 (bring AdGuard up)."
  exit 0
else
  warn "================  setup-pi FAILED — see the red lines above  ================"
  exit 1
fi
