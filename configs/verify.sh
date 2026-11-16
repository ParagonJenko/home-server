#!/usr/bin/env bash
# verify.sh <STEP> — run a step's automated checks and print a clear PASS/FAIL,
# the way branch-missing-test.sh does for B4. Run it on the box the step targets.
#
# Only steps with a deterministic check are automated here. Steps verified by eye
# or by hand (a phone resolving a name, an alert arriving in Discord, pulling the
# mains) can't be scripted and stay as manual checks in the runbook.
# Untested on hardware — treat a first PASS as "worth a sanity glance".
source "$(dirname "$0")/lib/common.sh"
set +e                       # common.sh sets -e; checks are allowed to fail
PASS=0; FAIL=0
yes_() { ok   "  PASS  $*"; PASS=$((PASS + 1)); }
no_()  { warn "  FAIL  $*"; FAIL=$((FAIL + 1)); }

STEP="${1:-}"
[ -n "$STEP" ] || { echo "usage: $0 <STEP>   e.g. $0 B2"; exit 2; }
[ "$(id -u)" -eq 0 ] || warn "(not root — some checks may fail; re-run with sudo)"
hdr "Verify ${STEP}"

case "$STEP" in
  A2)
    pveversion | grep -qE 'pve-manager/9\.([2-9]|[1-9][0-9])' \
      && yes_ "Proxmox 9.2 or newer" || no_ "Proxmox 9.2 or newer"
    pveum user token list claude@pve --output-format json 2>/dev/null \
      | jq -e '.[]|select(.tokenid=="automation")' >/dev/null \
      && yes_ "automation token exists" || no_ "automation token exists"
    pveum role list --output-format json 2>/dev/null \
      | jq -e '.[]|select(.roleid=="ClaudeAutomation")|select(.privs|contains("Sys.Console")|not)' >/dev/null \
      && yes_ "ClaudeAutomation role has NO Sys.Console" || no_ "ClaudeAutomation role has NO Sys.Console"
    ;;
  A3)
    grep -qE '^[[:space:]]*thin_pool_autoextend_threshold[[:space:]]*=' /etc/lvm/lvm.conf \
      && yes_ "autoextend threshold set (not commented)" || no_ "autoextend threshold set"
    grep -qE '^[[:space:]]*thin_pool_autoextend_percent[[:space:]]*=' /etc/lvm/lvm.conf \
      && yes_ "autoextend percent set" || no_ "autoextend percent set"
    ;;
  B2)
    findmnt -no FSTYPE /mnt/media 2>/dev/null | grep -q fuse.mergerfs \
      && yes_ "/mnt/media is a mergerfs mount" || no_ "/mnt/media is a mergerfs mount"
    szg=$(df -BG --output=size /mnt/media 2>/dev/null | tail -1 | tr -dc '0-9')
    [ "${szg:-0}" -ge 6000 ] && yes_ "pool ~7T (${szg}G)" || no_ "pool size (~7T, got ${szg:-?}G)"
    own=$(stat -c '%u:%g' /mnt/media/torrents 2>/dev/null)
    [ "$own" = "1000:1000" ] && yes_ "torrents owned by 1000:1000" || no_ "torrents ownership (got ${own:-none})"
    ;;
  C1)
    pveam list local 2>/dev/null | grep -q 'debian-13' \
      && yes_ "Debian 13 template present in local" || no_ "Debian 13 template in local"
    ;;
  D3)
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qi adguard \
      && yes_ "AdGuard container running" || no_ "AdGuard container running"
    grep -q '127.0.0.1' /etc/resolv.conf 2>/dev/null \
      && yes_ "Pi resolver is 127.0.0.1" || no_ "Pi resolver = 127.0.0.1 (nmcli ipv4.dns)"
    getent hosts pi.home >/dev/null 2>&1 \
      && yes_ "pi.home resolves — internal DNS works" || no_ "pi.home resolves via AdGuard"
    ;;
  D2)
    docker run --rm hello-world >/dev/null 2>&1 \
      && yes_ "docker runs (hello-world)" || no_ "docker runs (hello-world)"
    [ -z "$(swapon --show 2>/dev/null)" ] \
      && yes_ "swap is off" || no_ "swap is off"
    grep -q '^GF_SECURITY_ADMIN_PASSWORD=..*' /opt/pi-stack/.env 2>/dev/null \
      && yes_ "Grafana admin password set in .env" || no_ "Grafana password in /opt/pi-stack/.env"
    HOOK="$(head -n1 /opt/pi-stack/alertmanager/discord-webhook-url 2>/dev/null)"
    if printf '%s' "$HOOK" | grep -qi 'discord.com/api/webhooks'; then
      code="$(curl -s -o /dev/null -w '%{http_code}' "$HOOK" 2>/dev/null)"
      [ "$code" = "200" ] \
        && yes_ "Discord webhook is live (GET returned 200 — no message sent)" \
        || no_ "Discord webhook present but GET returned ${code:-none} — check the URL is valid"
    else
      no_ "Discord webhook not set — paste it into /opt/pi-stack/alertmanager/discord-webhook-url before H1"
    fi
    ;;
  H2)
    curl -s localhost:9100/metrics 2>/dev/null | grep -q lvm_thinpool \
      && yes_ "node_exporter exposes lvm_thinpool" || no_ "lvm_thinpool metric (node_exporter + check-thinpool.sh)"
    ;;
  J3)
    curl -s localhost:9100/metrics 2>/dev/null | grep -q smartmon \
      && yes_ "smartmon metrics present" || no_ "smartmon metrics (smartmon.sh cron)"
    ;;
  J4)
    command -v unattended-upgrade >/dev/null 2>&1 && unattended-upgrade --dry-run >/dev/null 2>&1 \
      && yes_ "unattended-upgrade dry-run OK" || no_ "unattended-upgrade configured"
    ;;
  K2)
    command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1 \
      && yes_ "nvidia-smi sees the GPU" || no_ "GPU passthrough (nvidia-smi)"
    ;;
  B4)
    exec "$(dirname "$0")/mergerfs/branch-missing-test.sh"
    ;;
  B5)
    exec "$(dirname "$0")/lvm-filltest.sh"
    ;;
  *)
    warn "No automated check for '${STEP}'. This step is verified by hand — see the runbook's Verify note."
    exit 0
    ;;
esac

echo
if [ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]; then
  ok   "================  ${STEP} PASS — ${PASS}/${PASS} checks  ================"
  exit 0
else
  warn "================  ${STEP}: ${FAIL} failed, ${PASS} passed  ================"
  exit 1
fi
