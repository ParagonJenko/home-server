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
  # 6 GB RAM, NOT 2 GB: Sonarr+Radarr+Bazarr+Prowlarr+qBittorrent+FlareSolverr spike past 2 GB (a Bazarr
  # subtitle scan, or FlareSolverr spawning Chrome), spill to swap, and swap-thrash self-reinforces into
  # 504s. Host has 15 GB; 6 GB leaves plenty for Plex/nginx/amp. Per-service mem_limits (R6/R9) are set
  # in the stack's compose; this is the LXC-level ceiling above them.
  pct create "$CTID" "$(resolve_template)" \
    --hostname media-pipeline \
    --cores 2 --memory 6144 --swap 2048 \
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
# recyclarr (quality profiles) + qbit_manage (housekeeping) + decluttarr (queue cleanup) configs
pct exec "$CTID" -- mkdir -p /opt/recyclarr/config /opt/qbit_manage/config /opt/decluttarr/config
pct push "$CTID" ../media-pipeline/recyclarr.yml /opt/recyclarr/config/recyclarr.yml
pct push "$CTID" ../media-pipeline/qbit_manage.config.yml /opt/qbit_manage/config/config.yml
pct push "$CTID" ../media-pipeline/decluttarr.config.yaml /opt/decluttarr/config/config.yaml
# these three run as 1000:1000 (not LSIO, so they don't self-chown /config); the dirs must
# be owned by 1000 or they can't read config / write logs (R6 idmap: host 1000).
pct exec "$CTID" -- chown -R 1000:1000 /opt/recyclarr /opt/qbit_manage /opt/decluttarr

# Maintainerr (watch-based library cleanup) + Tdarr (re-encode to shrink the library). BOTH run as
# uid 1000, NOT root: Maintainerr v2's image is hardwired to `USER node` (uid 1000) with no PUID/PGID,
# so /opt/maintainerr/data MUST be owned by 1000 or the server crash-loops on "Could not create or
# access (files in) the data directory". Tdarr (uid 1000) keeps its transcode scratch on the POOL
# (a 4K transcode needs tens of GB — never the 20 G rootfs). Both are configured in their web UIs.
# /opt dirs live on the container rootfs — root-in-CT can make + chown them.
pct exec "$CTID" -- bash -c 'mkdir -p /opt/maintainerr/data /opt/tdarr/server /opt/tdarr/configs /opt/tdarr/logs && chown -R 1000:1000 /opt/tdarr /opt/maintainerr'
# Tdarr's transcode scratch lives on the POOL. root inside this unprivileged CT maps to a
# high host uid and CANNOT write the idmapped /data mount, so make the dir on the HOST pool
# path (/mnt/media is owned by host 1000 = the CT's media user). It then appears in-CT as
# /data/.tdarr_cache owned by 1000. (mkdir -p via `pct exec` here fails: Permission denied.)
mkdir -p /mnt/media/.tdarr_cache && chown 1000:1000 /mnt/media/.tdarr_cache

# maintainerr-keeper (Discord Keep/Delete bot). Deploy its code now; it is NOT started here — it
# needs the bot token first (gather-keeper-creds.sh), so starting it blind just crash-loops it.
pct exec "$CTID" -- mkdir -p /opt/maintainerr-keeper/data
pct push "$CTID" ../media-pipeline/maintainerr-keeper/bot.py /opt/maintainerr-keeper/bot.py
pct push "$CTID" ../media-pipeline/maintainerr-keeper/requirements.txt /opt/maintainerr-keeper/requirements.txt

# Phase 1: bring up only the apps that need no secrets. recyclarr/decluttarr/qbit_manage
# read .env (API keys + qBit creds) and have nothing to do until those exist, so they're
# started in phase 2 after the keys are filled — starting them now just crash-loops them.
say "start the core apps (qBittorrent + Arr stack)"
pct exec "$CTID" -- bash -c 'cd /opt/media-pipeline && docker compose up -d \
  qbittorrent sonarr radarr bazarr prowlarr flaresolverr maintainerr tdarr'

ok "Core apps up — qBittorrent + Arr stack running (phase 2 is manual; recyclarr/decluttarr/qbit_manage wait for .env keys)."
say "maintainerr-keeper deployed but NOT started — run ./configs/media-pipeline/gather-keeper-creds.sh to add the Discord bot token, which starts it."
