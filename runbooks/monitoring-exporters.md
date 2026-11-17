# Application exporters

The base monitoring (node_exporter, blackbox, SMART) watches the *infrastructure*. These exporters
add *application* visibility — what's happening inside Proxmox, Plex, the Arrs, PBS, etc. They run as
containers in the Pi stack (`configs/pi/docker-compose.yaml`), all on host networking, each scraped by
Prometheus. **Every credential lives in the gitignored `configs/pi/.env`** (chmod 600) — never commit
one (R21). After editing `.env`: `cd /opt/pi-stack && docker compose up -d` to restart the exporter.

Deploy pattern for all of them: fill the keys in `.env`, `git pull`, `./configs/pi/redeploy.sh`
(starts new containers + reloads Prometheus + Grafana).

## Gather every credential in one shot

Instead of clicking through each app's UI, run the collector **on the Pi** — it SSHes to nuc1 and PBS,
creates the PVE/PBS monitoring tokens, reads the Plex token and Arr API keys out of the app configs, and
prints a ready-to-paste `.env` block:

```bash
cd ~/home-server && git pull
./configs/pi/gather-exporter-creds.sh          # add --rotate to recreate tokens that already exist
```

- Tokens that don't exist yet are **created** and their one-time value printed; existing ones are left
  alone (re-run with `--rotate` to delete+recreate for a fresh value).
- Plex token, the three Arr API keys, qBit + AdGuard **usernames** are read directly from the boxes.
- The two WebUI **passwords** (qBittorrent, AdGuard) are hashed on disk and can't be extracted — the
  script leaves `QBIT_PASS=`/`ADGUARD_PASS=` blank for you to fill with what you log in with.

Secrets print to the terminal only — nothing is written or committed (R21). Paste the block into
`/opt/pi-stack/.env`, then `cd /opt/pi-stack && docker compose up -d` (or `./configs/pi/redeploy.sh`).

Prefer passwordless qBittorrent? Whitelist the Pi in qBittorrent → Settings → Web UI → "Bypass
authentication for clients in whitelisted IP subnets" → add `192.168.1.4/32`, then leave `QBIT_USER`/
`QBIT_PASS` blank.

---

## Proxmox — pve-exporter  ✅

Per-VM/LXC and per-node CPU, memory, disk and run-state across both nodes. Binds `:9221`; Prometheus
scrapes it multi-target (one scrape per node, `?target=<ip>`).

**Token** (read-only, cluster-wide — run on either NUC):
```bash
pveum user token add claude@pve monitoring --privsep 0
pveum acl modify / --roles PVEAuditor --tokens 'claude@pve!monitoring'
```
The `add` prints the token **value once** — paste it into `.env` as `PVE_TOKEN_VALUE`. `PVEAuditor` is
read-only (no VM.Audit of consoles, no changes), so this token can't alter anything.

**`.env`:**
```
PVE_USER=claude@pve
PVE_TOKEN_NAME=monitoring
PVE_TOKEN_VALUE=<the value printed above>
PVE_VERIFY_SSL=false
```

**Dashboard:** Grafana → **Proxmox guests** (guest status, CPU/mem/disk per guest, node + storage %).
**Verify:** Prometheus → Status → Targets → `pve` shows both nodes UP; `curl -s localhost:9221/pve?target=192.168.1.2 | head`.
**Note:** VM disk % needs the QEMU guest agent inside the VM; LXC rootfs reports without it.

---

## Media stack — Plex, qBittorrent, Arrs  ✅

Five exporters, all scraping services in LXC 210/220 over the LAN.

| Exporter | Port | `.env` keys | Gives |
|---|---|---|---|
| plex-exporter | 9000 | `PLEX_TOKEN` | active streams, bandwidth, library counts |
| qbittorrent-exporter | 9238 | `QBIT_USER`, `QBIT_PASS` | up/down speed, torrents by state, ratio |
| exportarr-sonarr | 9707 | `SONARR_API_KEY` | queue, series, missing, health |
| exportarr-radarr | 9708 | `RADARR_API_KEY` | queue, movies, missing, health |
| exportarr-prowlarr | 9710 | `PROWLARR_API_KEY` | indexers, grabs, health |

**Getting the keys:** Plex token — open any item in Plex web → ⋯ → Get Info → View XML, copy the
`X-Plex-Token=` from the URL. qBittorrent — its WebUI login. Arrs — each app → Settings → General → API Key.

**Dashboard:** Grafana → **Media stack** (Plex / Downloads / Library automation sections).
**Alert:** `ArrHealthIssue` (warning) fires when Sonarr/Radarr/Prowlarr reports a self-health problem.
**Metric-name caveat:** Plex exporter metric names vary by version — if the Plex panels show *No data*,
`curl -s localhost:9000/metrics | grep -i plex` and adjust the queries in `media.json`. qBittorrent/Arr
names are stable.

---

## PBS — pbs-exporter  ✅

Datastore usage, snapshot counts and reachability, read from the PBS API with a read-only token.
Binds `:10019`. Complements `verify-backups.sh` (which checks ages by CLI).

**Token** (run on the PBS VM / shell):
```bash
proxmox-backup-manager user generate-token root@pam monitoring
proxmox-backup-manager acl update / Audit --auth-id 'root@pam!monitoring'
```
Paste the printed value into `.env` as `PBS_TOKEN_VALUE` (name stays `monitoring`).

**Dashboard:** Grafana → **PBS backups** (datastore used %, size/available, snapshots per guest, PBS reachable).
**Alert:** `PBSDatastoreFull` (warning) at 85% datastore use.
**Metric-name caveat:** this exporter's metric names (`pbs_used`/`pbs_size`/`pbs_snapshot_count` …) can
differ by version — if panels show *No data*, `curl -s localhost:10019/metrics | grep pbs_` and adjust
`pbs.json` + the `PBSDatastoreFull` expr to match.

---

## Frigate + AdGuard  ✅

**AdGuard — adguard-exporter** (`:9617`): query volume, block rate, processing time. AdGuard runs on
this same host, so the exporter points at `127.0.0.1:8081` with the admin login in `.env`
(`ADGUARD_USER`/`ADGUARD_PASS` — the credentials you set in the AdGuard wizard).

**Frigate — native** (no container): Frigate serves Prometheus metrics at `http://frigate-lxc:5000/metrics`;
Prometheus scrapes it directly (LAN only — `:5000` is never exposed, per services.md). Gives camera/detection
FPS, skipped frames, detector inference speed, storage.

**Dashboard:** Grafana → **DNS & NVR** (AdGuard section + Frigate section).
**Verify:** Prometheus → Targets → `adguard` and `frigate` UP.
**Caveats:**
- AdGuard metric names vary by exporter version — if No data, `curl -s localhost:9617/metrics | grep adguard_`.
- Frigate: if `frigate` target is DOWN, your Frigate version may serve metrics on a different path or
  require it enabled — check `curl -s http://frigate-lxc.home.alexjenkinson.com:5000/metrics | head`, and
  adjust the `frigate` job's `metrics_path`/port if needed. Camera labels are `camera_name`.

---

## Adding another exporter later

1. Add the service to `configs/pi/docker-compose.yaml` (host networking, a free port).
2. Put any secret in `configs/pi/.env` (and document it in `.env.example`, value blank).
3. Add a scrape job to `configs/pi/prometheus/prometheus.yml`.
4. Add a dashboard JSON under `configs/pi/grafana/dashboards/`.
5. `git pull && ./configs/pi/redeploy.sh` on the Pi. Check Prometheus → Targets.



