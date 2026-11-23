#!/usr/bin/env bash
# social-generator.sh — LXC 250: ideaSquared social asset generator (personal project).
# github.com/ideaSquared/social-generator (public) — its own deploy/docker-compose.yml runs
# automate.py on a timer (reads the Social posts sheet, renders with Chromium + ffmpeg) and an
# nginx review page on :8087. No media mount. Unprivileged, nesting+keyctl for Docker. [R6 R13 R21]
# Re-run to update: it git-pulls the project and rebuilds. Run as root on NUC-1.
set -euo pipefail
cd "$(dirname "$0")"
source ../lib/common.sh
source ./_require_filled.sh; source ./_template.sh
need_root

CTID=250
NS="192.168.1.4"        # the Pi (R13)
ROOTFS_CAP=20           # GB on local-lvm (storage.md) — Chromium image ~1.5 G + rendered output volume
REPO="https://github.com/ideaSquared/social-generator.git"   # public: anonymous read, no key on the box
APP=/opt/social-generator
LOCAL=../social-generator          # gitignored per-box files: .env + secrets/service-account.json

if pct status "$CTID" >/dev/null 2>&1; then
  warn "CT ${CTID} already exists — skipping create (pull + rebuild below)."
else
  say "create CT ${CTID} — social-generator"
  # 2.5 GB: the runner's compose mem_limit is 2g (Chromium renders + ffmpeg videos); the review
  # nginx is tiny. LXC ceiling sits just above the stack's own limit (storage.md RAM table).
  pct create "$CTID" "$(resolve_template)" \
    --hostname social-generator \
    --cores 2 --memory 2560 --swap 1024 \
    --rootfs "local-lvm:${ROOTFS_CAP}" \
    --unprivileged 1 --features nesting=1,keyctl=1 \
    --onboot 1 --startup order=4 \
    --nameserver "$NS" \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp
fi

say "start CT ${CTID} + install Docker + git"
pct start "$CTID" 2>/dev/null || true
pct push "$CTID" ./_install-docker.sh /root/_install-docker.sh
pct exec "$CTID" -- bash -c 'command -v docker >/dev/null || bash /root/_install-docker.sh'
pct exec "$CTID" -- bash -c 'command -v git >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git ca-certificates curl; }'

say "clone / update the project"
pct exec "$CTID" -- bash -c "if [ -d $APP/.git ]; then git -C $APP pull --ff-only; else git clone --depth 1 $REPO $APP; fi"

say "secrets + settings (never committed — R21)"
pct exec "$CTID" -- mkdir -p "$APP/deploy/secrets"
if [ -f "$LOCAL/.env" ]; then
  pct push "$CTID" "$LOCAL/.env" "$APP/deploy/.env"
else
  pct exec "$CTID" -- test -f "$APP/deploy/.env" \
    || pct push "$CTID" "$LOCAL/.env.example" "$APP/deploy/.env"
  warn "  no $LOCAL/.env — seeded from the example. Fill SHEET_ID (see configs/social-generator/README.md)."
fi
if [ -f "$LOCAL/secrets/service-account.json" ]; then
  pct push "$CTID" "$LOCAL/secrets/service-account.json" "$APP/deploy/secrets/service-account.json"
fi
# the runner runs as uid 1000 ('social' in its image) and reads the key read-only
pct exec "$CTID" -- bash -c "[ -f $APP/deploy/secrets/service-account.json ] && chown 1000:1000 $APP/deploy/secrets/service-account.json && chmod 600 $APP/deploy/secrets/service-account.json || true"
pct push "$CTID" ../social-generator/verify-social.sh "$APP/verify-social.sh"

# Don't start it blind: with no sheet source every pass just logs FAILED.
have_source="$(pct exec "$CTID" -- bash -c "
  . $APP/deploy/.env 2>/dev/null
  if [ -n \"\${SHEET_ID:-}\" ] && [ -f $APP/deploy/secrets/service-account.json ]; then echo yes
  elif [ -n \"\${SHEET_CSV_URL:-}\" ]; then echo yes; else echo no; fi")"
if [ "$have_source" = yes ]; then
  say "build + start (first build pulls Chromium — a few minutes on the N150)"
  pct exec "$CTID" -- bash -c "cd $APP/deploy && docker compose up -d --build"
  ok "social-generator up — review page on :8087 (https://social.home.alexjenkinson.com once DNS + nginx are in)."
  say "health: pct exec ${CTID} -- bash ${APP}/verify-social.sh"
else
  warn "NOT started — no sheet source yet. Put SHEET_ID in configs/social-generator/.env and the key at"
  warn "configs/social-generator/secrets/service-account.json (or set SHEET_CSV_URL), then re-run this script."
fi
