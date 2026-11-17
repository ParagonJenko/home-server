#!/usr/bin/env bash
# enable-tls.sh — issue the Let's Encrypt wildcard for *.home.alexjenkinson.com via
# Cloudflare DNS-01, install it for nginx, and switch the proxy to HTTPS. Runs INSIDE
# nginx LXC 240. Self-contained (no repo siblings), like datastore-setup.sh. [R20 R21]
#
#   pct exec 240 -- env CF_Token=<cloudflare-token> bash /opt/nginx/enable-tls.sh
#
# The token is a Cloudflare API token with Zone:DNS:Edit on the alexjenkinson.com zone.
# acme.sh installs its own renewal cron and re-runs the reload on every renewal.
set -euo pipefail
DOMAIN="home.alexjenkinson.com"
CERTDIR="/etc/nginx/certs"
: "${CF_Token:?set CF_Token to a Cloudflare API token with Zone:DNS:Edit on alexjenkinson.com}"
export CF_Token

command -v curl >/dev/null || { apt-get update && apt-get install -y curl; }

# Install acme.sh (self-contained ACME client; installs a daily renewal cron on first run).
if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
  curl -fsSL https://get.acme.sh | sh -s -- --home "$HOME/.acme.sh"
fi
ACME="$HOME/.acme.sh/acme.sh"
"$ACME" --set-default-ca --server letsencrypt

# Issue apex + wildcard (one cert covers every <service>.home.alexjenkinson.com front name).
mkdir -p "$CERTDIR"
"$ACME" --issue --dns dns_cf -d "$DOMAIN" -d "*.$DOMAIN" --keylength ec-256
"$ACME" --install-cert -d "$DOMAIN" --ecc \
  --key-file       "$CERTDIR/$DOMAIN.key" \
  --fullchain-file "$CERTDIR/$DOMAIN.crt" \
  --reloadcmd      "nginx -s reload"

# Activate the TLS config — nginx served the default site until the cert existed, so
# putting the :443 config live before now would have failed to load.
install -m 644 /opt/nginx/ssl.conf     /etc/nginx/snippets/homelab-ssl.conf
install -m 644 /opt/nginx/homelab.conf /etc/nginx/conf.d/homelab.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

echo
echo "TLS live. acme.sh will auto-renew and reload nginx. Verify: /opt/nginx/verify-nginx.sh"
echo "Store the Cloudflare token in your vault (R21) — the cert reissues from it on any rebuild."
