#!/usr/bin/env bash
# media-pipeline.sh — LXC 210: qBittorrent + the whole Arr stack in one container. [R6 R13]
# Unprivileged, nesting+keyctl, /mnt/media bind-mounted at /data, idmap, requires-mount.
# Run as root on NUC-1.
set -euo pipefail
cd "$(dirname "$0")"
source ../lib/common.sh
source ./_require_filled.sh; source ./_template.sh; source ./_idmap.sh; source ./_requires_mount.sh
need_root

CTID=210
NS="192.168.1.4"        # the Pi — the one literal IP a config may carry (R13)
ROOTFS_CAP=20           # GB on local-lvm (storage.md ceiling; downloads live on the pool, not here)

if pct status "$CTID" >/dev/null 2>&1; then
  warn "CT ${CTID} already exists — skipping create (idmap/mount re-applied below)."
else
  say "create CT ${CTID} — media-pipeline (qBittorrent + Arr stack)"
  pct create "$CTID" "$(resolve_template)" \
    --hostname media-pipeline \
    --cores 2 --memory 2048 --swap 512 \
    --rootfs "local-lvm:${ROOTFS_CAP}" \
    --mp0 /mnt/media,mp=/data \
    --unprivileged 1 --features nesting=1,keyctl=1 \
    --onboot 1 --startup order=3 \
    --nameserver "$NS" \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp
fi

apply_idmap "$CTID"                         # container 1000 -> host 1000 (shared media user)
apply_requires_mount "$CTID" /mnt/media     # refuse to start if the pool isn't mounted (R9)

say "start CT ${CTID} + install Docker"
pct start "$CTID" 2>/dev/null || true
pct push "$CTID" ./_install-docker.sh /root/_install-docker.sh
pct exec "$CTID" -- bash -c 'command -v docker >/dev/null || bash /root/_install-docker.sh'
# arr-setup.py (phase 2) runs inside this container; the minimal template has no python3
pct exec "$CTID" -- bash -c 'command -v python3 >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3; }'

say "deploy the compose stack"
pct exec "$CTID" -- mkdir -p /opt/media-pipeline
pct push "$CTID" ../media-pipeline/docker-compose.yaml /opt/media-pipeline/docker-compose.yaml
pct push "$CTID" ../media-pipeline/arr-setup.py /opt/media-pipeline/arr-setup.py          # phase 2
pct push "$CTID" ../media-pipeline/fill-arr-keys.sh /opt/media-pipeline/fill-arr-keys.sh  # phase 2
pct push "$CTID" ../media-pipeline/verify-media.sh /opt/media-pipeline/verify-media.sh    # health check
# set-qbit-pass.sh runs on the HOST (it prompts), so it stays in the repo, not the CT.
if [ -f ../media-pipeline/.env ]; then
  pct push "$CTID" ../media-pipeline/.env /opt/media-pipeline/.env
else
  # seed an empty .env (keys don't exist until the apps first boot) — but never clobber
  # one already filled in the container on a re-run.
  pct exec "$CTID" -- test -f /opt/media-pipeline/.env \
    || pct push "$CTID" ../media-pipeline/.env.example /opt/media-pipeline/.env
  warn "  .env seeded empty — fill the API keys after first boot (phase 2 below)."
fi
# quality-profile (recyclarr) + qBittorrent housekeeping (qbit_manage) configs
pct exec "$CTID" -- mkdir -p /opt/recyclarr/config /opt/qbit_manage/config
pct push "$CTID" ../media-pipeline/recyclarr.yml /opt/recyclarr/config/recyclarr.yml
pct push "$CTID" ../media-pipeline/qbit_manage.config.yml /opt/qbit_manage/config/config.yml
# recyclarr + qbit_manage run as 1000:1000 (not LSIO, so they don't self-chown /config);
# the dirs must be owned by 1000 or they can't write their logs/config (R6 idmap: host 1000).
pct exec "$CTID" -- chown -R 1000:1000 /opt/recyclarr /opt/qbit_manage

# Phase 1: bring up only the apps that need no secrets. recyclarr/decluttarr/qbit_manage
# read .env (API keys + qBit creds) and have nothing to do until those exist, so they're
# started in phase 2 after the keys are filled — starting them now just crash-loops them.
say "start the core apps (qBittorrent + Arr stack)"
pct exec "$CTID" -- bash -c 'cd /opt/media-pipeline && docker compose up -d \
  qbittorrent sonarr radarr bazarr prowlarr flaresolverr'

IP="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"
ok "Core stack up. Once nginx (LXC 240) + AdGuard rewrites are in, reach them by name:"
echo "     qbittorrent.home  sonarr.home  radarr.home  bazarr.home  prowlarr.home"
echo "   Until DNS resolves, use this LXC's IP directly:"
echo "     qBittorrent http://${IP}:8080   Sonarr http://${IP}:8989   Radarr http://${IP}:7878"
echo "     Prowlarr    http://${IP}:9696   Bazarr http://${IP}:6767"
echo "   Phase 2 — set a qBittorrent password in its WebUI (http://${IP}:8080) first, then:"
echo "     pct exec ${CTID} -- bash /opt/media-pipeline/fill-arr-keys.sh    # Arr keys -> .env"
echo "     ./configs/media-pipeline/set-qbit-pass.sh                        # record that password -> .env"
echo "     pct exec ${CTID} -- bash -c 'cd /opt/media-pipeline && docker compose up -d --force-recreate recyclarr decluttarr qbit_manage'"
echo "     pct exec ${CTID} -- bash -c 'cd /opt/media-pipeline && python3 arr-setup.py --apply'"
