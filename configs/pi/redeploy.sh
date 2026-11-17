#!/usr/bin/env bash
# redeploy.sh — push the repo's pi-stack configs into /opt and apply them. Run on the Pi after
# a git pull. Safe to re-run: it replaces the repo-managed config dirs, keeps the secrets
# (.env, the Discord webhook, AdGuard's runtime data), recreates containers whose spec changed,
# and reloads Prometheus/blackbox for their mounted configs.
set -euo pipefail
cd "$(dirname "$0")"
[ -d /opt/pi-stack ] || { echo "!! /opt/pi-stack not found — run setup-pi.sh first" >&2; exit 1; }

# Repo-managed config dirs (no secrets, no runtime data) — replace wholesale, avoiding cp-nesting.
# NB: NOT adguard/ — that holds AdGuardHome.yaml + runtime data, not repo config.
for d in prometheus blackbox grafana; do
  [ -d "./$d" ] || continue
  rm -rf "/opt/pi-stack/$d"
  cp -r "./$d" /opt/pi-stack/
done
cp ./alertmanager/alertmanager.yml /opt/pi-stack/alertmanager/ 2>/dev/null || true
chown 65534:65534 /opt/pi-stack/alertmanager/discord-webhook-url 2>/dev/null || true   # alertmanager uid
cp ./docker-compose.yaml /opt/pi-stack/
mkdir -p /opt/monitoring && cp ../monitoring/alerts.yml /opt/monitoring/ 2>/dev/null || true

cd /opt/pi-stack
docker compose up -d                        # recreate containers whose spec changed (blackbox/node_exporter)
docker compose restart prometheus blackbox  # reload mounted configs (scrape+rules, probe modules)
echo "redeployed. Grafana loads new/updated dashboards within ~30s (Dashboards → Homelab)."
