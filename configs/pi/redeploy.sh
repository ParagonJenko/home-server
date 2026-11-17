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
# from the PVE_* values in .env. Both .env and the rendered file are gitignored secrets. Always write
# the file (even empty-token) so the bind mount is a file, not a directory.
mkdir -p pve
if [ -f .env ]; then
  pv() { grep -m1 "^$1=" .env 2>/dev/null | cut -d= -f2- | sed 's/^"//; s/"$//'; }
  u=$(pv PVE_USER);        u=${u:-claude@pve}
  tn=$(pv PVE_TOKEN_NAME);  tn=${tn:-monitoring}
  tv=$(pv PVE_TOKEN_VALUE)
  vs=$(pv PVE_VERIFY_SSL);  vs=${vs:-false}
  cat > pve/pve.yml <<EOF
default:
  user: ${u}
  token_name: ${tn}
  token_value: "${tv}"
  verify_ssl: ${vs}
EOF
  chmod 600 pve/pve.yml
else
  : > pve/pve.yml
fi

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
