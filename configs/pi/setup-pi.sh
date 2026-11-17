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
systemctl restart systemd-journald >/dev/null 2>&1 || true
swapoff -a 2>/dev/null || true                                       # turn off all ACTIVE swap now
systemctl disable --now dphys-swapfile >/dev/null 2>&1 || true       # keep it off across reboots
command -v dphys-swapfile >/dev/null 2>&1 && dphys-swapfile uninstall >/dev/null 2>&1 || true
if [ -z "$(swapon --show 2>/dev/null)" ]; then ok "  swap off, journald volatile"
else warn "  swap still on — run: sudo swapoff -a"; FAIL=1; fi

say "deploy the stack into /opt (configs come from the repo — edit there, re-run to redeploy)"
mkdir -p /opt/pi-stack /opt/monitoring
if cp -r ./. /opt/pi-stack/ && cp -r ../monitoring/. /opt/monitoring/; then
  ok "  configs/pi -> /opt/pi-stack ; configs/monitoring -> /opt/monitoring"
else warn "  copy into /opt failed"; FAIL=1; fi

say "secrets — Grafana password (generated here) + Discord webhook (pasted here)"
(
  cd /opt/pi-stack || exit 1
  # Grafana admin password: generate once, keep it across re-runs (changing it would
  # break an existing Grafana login).
  if grep -q '^GF_SECURITY_ADMIN_PASSWORD=..*' .env 2>/dev/null; then
    ok "  Grafana password already set in .env — kept"
  else
    PW=$(openssl rand -base64 24 2>/dev/null || head -c 18 /dev/urandom | base64)
    printf 'GF_SECURITY_ADMIN_PASSWORD=%s\n' "$PW" > .env; chmod 600 .env
    hdr "============ Grafana admin login — shown once ============"
    echo  "  user: admin"
    printf '  password: '; save "$PW"
    echo  "========================================================="
    ok "  generated — SAVE this to your vault (R21)"
  fi
  # Discord webhook: paste it now, or skip and fill before H1.
  mkdir -p alertmanager
  if [ -s alertmanager/discord-webhook-url ] && grep -qi 'discord.com/api/webhooks' alertmanager/discord-webhook-url; then
    ok "  Discord webhook already set — kept"
  else
    warn "  Make one in Discord: Server Settings > Integrations > Webhooks > New Webhook > Copy URL"
    read -rp "$(printf '%s  Paste the Discord webhook URL (or Enter to skip for now):%s ' "$C_WARN" "$C_RST")" HOOK
    if [ -n "${HOOK:-}" ]; then
      printf '%s\n' "$HOOK" > alertmanager/discord-webhook-url; chmod 600 alertmanager/discord-webhook-url
      ok "  webhook saved — also store it in your vault (R21)"
    else
      : > alertmanager/discord-webhook-url; chmod 600 alertmanager/discord-webhook-url   # must exist as a FILE
      warn "  skipped — paste it into /opt/pi-stack/alertmanager/discord-webhook-url before H1"
    fi
  fi
  # The alertmanager container runs as uid 65534 (nobody) and reads this file at notify time.
  # A root:root 600 file gives it "permission denied" — hand ownership to the container user.
  chown 65534:65534 alertmanager/discord-webhook-url 2>/dev/null || true
) || FAIL=1

echo
if [ "$FAIL" -eq 0 ]; then
  ok "================  setup-pi PASS — it all worked  ================"
  ok "Grafana password generated, webhook saved (or skip-and-fill noted). Next: D3 (bring AdGuard up)."
  exit 0
else
  warn "================  setup-pi FAILED — see the red lines above  ================"
  exit 1
fi
