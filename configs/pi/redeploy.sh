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

# pve-exporter reads ONLY /etc/prometheus/pve.yml (it ignores PVE_* env vars), so render that file
# from the PVE_* values in .env. Both .env and the rendered file are gitignored secrets. This block
# must NEVER abort the render (every helper ends in '|| true'), and always leaves a FILE — if a
# previous failed mount left a directory at that path, remove it first.
mkdir -p pve
if [ -d pve/pve.yml ]; then rm -rf pve/pve.yml; fi
pv() { grep -m1 "^$1=" .env 2>/dev/null | cut -d= -f2- | sed 's/^"//; s/"$//' || true; }
u=""; tn=""; tv=""; vs=""
if [ -f .env ]; then u=$(pv PVE_USER); tn=$(pv PVE_TOKEN_NAME); tv=$(pv PVE_TOKEN_VALUE); vs=$(pv PVE_VERIFY_SSL); fi
cat > pve/pve.yml <<EOF
default:
  user: ${u:-claude@pve}
  token_name: ${tn:-monitoring}
  token_value: "${tv}"
  verify_ssl: ${vs:-false}
EOF
chmod 600 pve/pve.yml
if [ -z "$tv" ]; then echo "!! PVE_TOKEN_VALUE is empty in .env — pve-exporter will fail auth until you add it (gather-exporter-creds.sh)" >&2; fi

docker compose up -d \
  || echo "!! some containers failed to start/pull (see above) — continuing to reload core configs" >&2
# ^ non-fatal: a single unpullable/unconfigured exporter must NOT block reloading the core stack below.
docker compose restart prometheus blackbox grafana alertmanager  # reload mounted configs:
                                                    # prometheus (scrape+rules), blackbox (probe modules),
                                                    # grafana (datasource + dashboard PROVIDERS — only
                                                    # re-read at boot, so 'up -d' alone never registers
                                                    # newly-added dashboards), alertmanager (routes + the
                                                    # Discord embed template)
echo "redeployed. Dashboards appear under Grafana → Dashboards within a few seconds of the restart."
