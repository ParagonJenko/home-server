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
set +o pipefail              # 'curl | grep -q' makes curl SIGPIPE on an early match; without this,
                             # pipefail turns a successful MATCH into a false FAIL (bit H2 live)
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
    getent hosts pi.home.alexjenkinson.com >/dev/null 2>&1 \
      && yes_ "pi.home.alexjenkinson.com resolves — internal DNS works" || no_ "pi.home.alexjenkinson.com resolves via AdGuard"
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
  H1)
    for c in grafana prometheus alertmanager; do
      docker ps --format '{{.Names}}' 2>/dev/null | grep -qi "$c" \
        && yes_ "${c} container running" || no_ "${c} container running"
    done
    curl -fsS localhost:3000/api/health 2>/dev/null | grep -qiE '"database"[[:space:]]*:[[:space:]]*"ok"' \
      && yes_ "Grafana health: database ok (:3000)" || no_ "Grafana health (:3000)"
    curl -fsS localhost:9090/-/healthy 2>/dev/null | grep -qi healthy \
      && yes_ "Prometheus healthy (:9090)" || no_ "Prometheus healthy (:9090)"
    curl -fsS localhost:9093/-/healthy >/dev/null 2>&1 \
      && yes_ "Alertmanager healthy (:9093)" || no_ "Alertmanager healthy (:9093)"
    curl -fsS localhost:9090/api/v1/targets 2>/dev/null | grep -q '"health":"up"' \
      && yes_ "Prometheus has a target UP (the pi node; nuc1/nuc2 stay DOWN until H2)" \
      || no_ "Prometheus targets — none UP yet (datasource/scrape config?)"
    ;;
  H2)
    curl -s localhost:9100/metrics 2>/dev/null | grep -q lvm_thinpool \
      && yes_ "node_exporter exposes lvm_thinpool" || no_ "lvm_thinpool metric (node_exporter + check-thinpool.sh)"
    ;;
  H4)
    # Sends a REAL test alert to your Discord channel — that's the point of this check.
    AM=http://localhost:9093; PROM=http://localhost:9090
    COMPOSE="docker compose -f /opt/pi-stack/docker-compose.yaml"
    # 1. Prometheus loaded every alert rule
    rules="$(curl -s "${PROM}/api/v1/rules" 2>/dev/null)"
    for a in DiskUsageHigh ThinPoolMetadataHigh ServiceDown ProbeFailed InternalDNSBroken; do
      printf '%s' "$rules" | grep -q "\"$a\"" && yes_ "rule ${a} loaded" || no_ "rule ${a} NOT loaded in Prometheus"
    done
    # 2. Fire a test alert, confirm Alertmanager accepts it and delivers to Discord with no failure
    fail0="$(curl -s "${AM}/metrics" 2>/dev/null | awk '/^alertmanager_notifications_failed_total.*discord/{s+=$2} END{print s+0}')"
    $COMPOSE exec -T alertmanager amtool alert add alertname=VerifyH4 severity=warning instance=pi \
      --alertmanager.url="$AM" >/dev/null 2>&1
    sleep 10
    curl -s "${AM}/api/v2/alerts" 2>/dev/null | grep -q VerifyH4 \
      && yes_ "test alert accepted by Alertmanager" || no_ "test alert not visible in Alertmanager (amtool/compose ok?)"
    sent="$(curl -s "${AM}/metrics" 2>/dev/null | awk '/^alertmanager_notifications_total.*discord/{s+=$2} END{print s+0}')"
    fail1="$(curl -s "${AM}/metrics" 2>/dev/null | awk '/^alertmanager_notifications_failed_total.*discord/{s+=$2} END{print s+0}')"
    awk "BEGIN{exit !(${sent:-0}>0)}"            && yes_ "Discord notifications recorded (total=${sent})" || no_ "no Discord notification sent — is the webhook pasted into discord-webhook-url?"
    awk "BEGIN{exit !(${fail1:-0}<=${fail0:-0})}" && yes_ "no new failed Discord deliveries"            || no_ "Discord delivery FAILED (failed ${fail0} -> ${fail1}) — bad webhook URL; see: docker compose logs alertmanager"
    ;;
  I2)
    # Guardrails are per host: the media pool + containers 210/220 live on NUC-1 only, so on
    # a host without them these report "n/a", not FAIL.
    # R9: no container rootfs on the media pool
    grep -h '^rootfs:' /etc/pve/lxc/*.conf 2>/dev/null | grep -qi 'media' \
      && no_ "a container rootfs sits on the media pool (R9)" \
      || yes_ "no container rootfs on the media pool (R9)"
    # R6: every container rootfs on this host is size-capped
    capbad=""
    for f in /etc/pve/lxc/*.conf; do
      [ -e "$f" ] || continue
      r="$(grep '^rootfs:' "$f" 2>/dev/null)"; [ -n "$r" ] || continue
      echo "$r" | grep -q 'size=' || capbad="${capbad} $(basename "$f" .conf)"
    done
    [ -z "$capbad" ] && yes_ "every container rootfs is size-capped (R6)" || no_ "rootfs with no size cap (R6):${capbad}"
    # R8/R9: mergerfs pool guardrails — only where the pool actually lives
    if grep -q mergerfs /etc/fstab 2>/dev/null; then
      grep mergerfs /etc/fstab | grep -q minfreespace        && yes_ "mergerfs minfreespace set (R8)"      || no_ "mergerfs minfreespace missing (R8)"
      grep mergerfs /etc/fstab | grep -q 'x-systemd.requires' && yes_ "pool requires its branches (R9)"    || no_ "pool branches ordering-only, not a dependency (R9)"
    else
      yes_ "no media pool on this host — mergerfs checks n/a"
    fi
    # R9: media-mount containers on THIS host refuse to start without the mount
    mfound=""
    for id in $(pct list 2>/dev/null | awk 'NR>1{print $1}'); do
      grep -qE '^mp[0-9]+:.*(/data|/mnt/media)' "/etc/pve/lxc/${id}.conf" 2>/dev/null || continue
      mfound=1
      systemctl cat "pve-container@${id}" 2>/dev/null | grep -q RequiresMountsFor \
        && yes_ "CT ${id} requires its media mount (R9)" \
        || no_ "CT ${id} would start against an empty dir — apply_requires_mount (R9)"
    done
    [ -z "$mfound" ] && yes_ "no media-mount containers on this host — check n/a"
    # R13: no UNEXPECTED literal IPs in configs/. Allowed: the Pi resolver (.4, the documented
    # exception), gateway (.1), localhost, public DNS 1.1.1.1 (install-time + AdGuard upstream),
    # network CIDRs, and the static-infra bootstrap IPs reached before DNS is guaranteed
    # (NUCs .2/.3, PBS .5, HA .25, Plex custom-URL .22).
    ALLOW="127.0.0.1 1.1.1.1 192.168.1.1 192.168.1.4 192.168.1.0 100.64.0.0 192.168.1.2 192.168.1.3 192.168.1.5 192.168.1.22 192.168.1.25"
    badip=""
    while IFS= read -r ip; do
      case " $ALLOW " in *" $ip "*) continue;; esac
      badip="${badip} ${ip}"
    done < <(grep -rhoE '([0-9]{1,3}\.){3}[0-9]{1,3}' configs/ 2>/dev/null | sort -u)
    [ -z "$badip" ] && yes_ "no unexpected literal IPs in configs/ (only Pi/gateway/infra-bootstrap) (R13)" \
      || no_ "unexpected literal IP(s) in configs/ — should be DNS names (R13):${badip}  (grep -rn to find them)"
    # R8: reserved blocks set on each mounted ext4 filesystem (root + DAS -m1), so a full data
    # disk still leaves root headroom.
    while read -r src tgt fst; do
      [ "$fst" = ext4 ] || continue
      rb="$(tune2fs -l "$src" 2>/dev/null | awk -F: '/Reserved block count/{gsub(/ /,"",$2);print $2}')"
      bc="$(tune2fs -l "$src" 2>/dev/null | awk -F: '/Block count/ && !/Reserved/{gsub(/ /,"",$2);print $2; exit}')"
      if [ -n "$rb" ] && [ "$rb" -gt 0 ] 2>/dev/null; then
        yes_ "reserved blocks set on ${tgt} ($(awk "BEGIN{printf \"%.1f%%\", ($rb/${bc:-1})*100}"))"
      else
        no_ "NO reserved blocks on ${tgt} (${src}) — set with: tune2fs -m 1 ${src} (R8)"
      fi
    done < <(findmnt -rno SOURCE,TARGET,FSTYPE 2>/dev/null)
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
