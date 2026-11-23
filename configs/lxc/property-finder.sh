#!/usr/bin/env bash
# property-finder.sh — LXC 260: local-property-finder (personal project).
# github.com/ParagonJenko/local-property-finder (PRIVATE) — scraper (Playwright Chromium) + API +
# React frontend, all `network_mode: host` in its own docker-compose.yml: frontend :3000 (which
# proxies /api to :3001), API :3001. SQLite + config.yaml in /opt/local-property-finder/data.
# Unprivileged, nesting+keyctl for Docker, no media mount. [R6 R13 R21]
#
# The repo is private, so the CT gets its OWN read-only GitHub deploy key (generated in the CT,
# never leaves it). Same rule as home-server: boxes pull, they never push.
# Re-run to update: it git-pulls the project and rebuilds. Run as root on NUC-1.
set -euo pipefail
cd "$(dirname "$0")"
source ../lib/common.sh
source ./_require_filled.sh; source ./_template.sh
need_root

CTID=260
NS="192.168.1.4"        # the Pi (R13)
ROOTFS_CAP=16           # GB on local-lvm (storage.md) — Playwright Chromium layer + SQLite DB
REPO="git@github.com:ParagonJenko/local-property-finder.git"
KEYS_URL="https://github.com/ParagonJenko/local-property-finder/settings/keys/new"
APP=/opt/local-property-finder
DATA="$APP/data"
FRONT="https://property.home.alexjenkinson.com"
LOCAL=../property-finder           # gitignored per-box files: .env + config.yaml

if pct status "$CTID" >/dev/null 2>&1; then
  warn "CT ${CTID} already exists — skipping create (pull + rebuild below)."
else
  say "create CT ${CTID} — property-finder"
  # 1.5 GB: API + nginx are light; the scraper's headless Chromium is the spike, and it only
  # runs every SCRAPER_INTERVAL_HOURS (6). Raise here + storage.md if GuestMemoryHigh fires.
  pct create "$CTID" "$(resolve_template)" \
    --hostname property-finder \
    --cores 2 --memory 1536 --swap 1024 \
    --rootfs "local-lvm:${ROOTFS_CAP}" \
    --unprivileged 1 --features nesting=1,keyctl=1 \
    --onboot 1 --startup order=4 \
    --nameserver "$NS" \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp
fi

say "start CT ${CTID} + install Docker + git/ssh"
pct start "$CTID" 2>/dev/null || true
pct push "$CTID" ./_install-docker.sh /root/_install-docker.sh
pct exec "$CTID" -- bash -c 'command -v docker >/dev/null || bash /root/_install-docker.sh'
pct exec "$CTID" -- bash -c 'command -v git >/dev/null && command -v ssh >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git openssh-client ca-certificates curl; }'

say "read-only deploy key (private repo)"
pct exec "$CTID" -- bash -c '
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  [ -f /root/.ssh/lpf_deploy ] || ssh-keygen -q -t ed25519 -N "" -C "property-finder@nuc1 read-only" -f /root/.ssh/lpf_deploy
  grep -q "^github.com " /root/.ssh/known_hosts 2>/dev/null || ssh-keyscan -t ed25519 github.com >> /root/.ssh/known_hosts 2>/dev/null
  grep -q lpf_deploy /root/.ssh/config 2>/dev/null || printf "Host github.com\n  IdentityFile /root/.ssh/lpf_deploy\n  IdentitiesOnly yes\n" >> /root/.ssh/config'

if ! pct exec "$CTID" -- test -d "$APP/.git"; then
  hdr "Add this as a deploy key — Title: property-finder@nuc1, 'Allow write access' UNTICKED:"
  save "$(pct exec "$CTID" -- cat /root/.ssh/lpf_deploy.pub)"
  echo "  $KEYS_URL"
  pause "Deploy key added on GitHub (read-only)."
  say "clone the project"
  pct exec "$CTID" -- git clone --depth 1 "$REPO" "$APP"
else
  say "update the project"
  pct exec "$CTID" -- git -C "$APP" pull --ff-only
fi

say "settings + config (never committed — R21: config.yaml holds the Discord webhooks)"
pct exec "$CTID" -- mkdir -p "$DATA"
if [ -f "$LOCAL/.env" ]; then
  pct push "$CTID" "$LOCAL/.env" "$APP/.env"
else
  pct exec "$CTID" -- test -f "$APP/.env" \
    || pct push "$CTID" "$LOCAL/.env.example" "$APP/.env"
fi
have_config=no
if [ -f "$LOCAL/config.yaml" ]; then
  pct push "$CTID" "$LOCAL/config.yaml" "$DATA/config.yaml"; have_config=yes
elif pct exec "$CTID" -- test -f "$DATA/config.yaml"; then
  have_config=yes          # already filled in the CT on an earlier run — never clobber it
fi
pct push "$CTID" ../property-finder/verify-property.sh "$APP/verify-property.sh"

# Don't start it blind: the example config's areas/webhooks are placeholders.
if [ "$have_config" = yes ]; then
  say "build + start (first build installs Playwright Chromium — a few minutes on the N150)"
  pct exec "$CTID" -- bash -c "cd $APP && docker compose up -d --build"
  ok "property-finder up — UI on :3000 (${FRONT} once DNS + nginx are in)."
  say "health: pct exec ${CTID} -- bash ${APP}/verify-property.sh"
else
  warn "NOT started — no config.yaml. Copy the project's config.yaml.example to configs/property-finder/config.yaml,"
  warn "fill your areas/tiers/webhooks, then re-run this script."
fi
