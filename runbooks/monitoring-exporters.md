# Application exporters

The base monitoring (node_exporter, blackbox, SMART) watches the *infrastructure*. These exporters
add *application* visibility — what's happening inside Proxmox, Plex, the Arrs, PBS, etc. They run as
containers in the Pi stack (`configs/pi/docker-compose.yaml`), all on host networking, each scraped by
Prometheus. **Every credential lives in the gitignored `configs/pi/.env`** (chmod 600) — never commit
one (R21). After editing `.env`: `cd /opt/pi-stack && docker compose up -d` to restart the exporter.

Deploy pattern for all of them: fill the keys in `.env`, `git pull`, `./configs/pi/redeploy.sh`
(starts new containers + reloads Prometheus + Grafana).

## Set up every credential — interactive wizard

Run the wizard **on the Pi**. It walks each credential one at a time and writes it straight into
`/opt/pi-stack/.env` as you go — no manual pasting:

```bash
cd ~/home-server && git pull
./configs/pi/gather-exporter-creds.sh
```

How it works per item:
- It first reads what it can off the boxes (Plex token, the three Arr API keys, the qBit + AdGuard
  **usernames**) and offers each as a `[suggestion]` — press **Enter** to accept, type to override, or
  leave blank to skip.
- **PVE and PBS tokens:** it asks whether to create/rotate the monitoring token now; on yes it creates it
  on the box and saves the value. (Say no and it lets you paste an existing one.)
- **qBittorrent + AdGuard passwords:** typed **hidden** (they're hashed on disk, can't be read back) —
  enter the password you log in with.
- At the end it offers to `docker compose up -d` for you.

Nothing is committed; values only ever land in the gitignored `.env` (R21). Re-run it any time to change
or add a credential — it replaces lines in place.

Prefer passwordless qBittorrent? Whitelist the Pi in qBittorrent → Settings → Web UI → "Bypass
authentication for clients in whitelisted IP subnets" → add `192.168.1.4/32`, then just skip the qBit
prompts in the wizard.

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

## Media stack — qBittorrent, Arrs (+ Plex, see note)  ✅

Exporters scraping services in LXC 210/220 over the LAN.

| Exporter | Port | `.env` keys | Gives |
|---|---|---|---|
| qbittorrent-exporter | 9238 | `QBIT_USER`, `QBIT_PASS` | up/down speed, torrents by state, ratio |
| exportarr-sonarr | 9707 | `SONARR_API_KEY` | queue, series, missing, health |
| exportarr-radarr | 9708 | `RADARR_API_KEY` | queue, movies, missing, health |
| exportarr-prowlarr | 9710 | `PROWLARR_API_KEY` | indexers, grabs, health |

**Getting the keys:** qBittorrent — its WebUI login. Arrs — each app → Settings → General → API Key.
(`gather-exporter-creds.sh` reads the Arr keys for you.)

**Dashboard:** Grafana → **Media stack** (Downloads / Library automation sections; Plex section fills in once Plex is wired — see below).
**Alert:** `ArrHealthIssue` (warning) fires when Sonarr/Radarr/Prowlarr reports a self-health problem.

### Plex — runs on nuc1, not the Pi ⚠️

The common Plex exporter image (`jsclayton/prometheus-plex-exporter`) is **amd64-only**, and the Pi is
**arm64**, so it can't run in the Pi stack. Run it on an **amd64 box next to Plex** instead — the Plex
LXC (220) on nuc1. Add this service to **LXC 220's** docker compose (not the Pi's):

```yaml
  plex-exporter:
    image: ghcr.io/jsclayton/prometheus-plex-exporter:latest
    network_mode: host                     # binds :9000 on the Plex LXC
    environment:
      PLEX_SERVER: http://localhost:32400
      PLEX_TOKEN: <your Plex token>         # the wizard still collects PLEX_TOKEN into the Pi .env
    restart: unless-stopped
```

Then add a scrape job to `configs/pi/prometheus/prometheus.yml` pointing at the Plex LXC:
```yaml
  - job_name: plex
    static_configs: [ { targets: ['plex-lxc.home.alexjenkinson.com:9000'] } ]
```
`./configs/pi/redeploy.sh` to reload Prometheus. The **Media stack** dashboard's Plex panels then
populate (metric names vary by exporter version — if *No data*, `curl -s plex-lxc…:9000/metrics | grep -i plex`
and adjust `media.json`). A multi-arch alternative is Tautulli + a Tautulli exporter.

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

**Frigate — metrics-only sidecar** (`:9101`): Frigate 0.18 serves metrics at `/api/metrics`, unauthenticated
but on its **loopback-bound `:5000`** (so unreachable from the LAN; `/api/metrics` on the authed `:8971` is
401). A tiny nginx sidecar (`configs/frigate/metrics-proxy.conf`) runs in Frigate's own network namespace
(`network_mode: service:frigate`), reaches `127.0.0.1:5000`, and exposes **only** `/metrics` → `/api/metrics`
on `:9101`, 403 for everything else — so the full unauth `:5000` API stays unreachable (services.md).
Prometheus scrapes `frigate-lxc:9101/metrics`. Gives camera/detection FPS, skipped frames, inference, storage.

**Deploy the Frigate side** (on nuc2, after `git pull` in `~/home-server`):
```bash
pct push 111 ~/home-server/configs/frigate/docker-compose.yaml /opt/frigate/docker-compose.yaml
pct push 111 ~/home-server/configs/frigate/metrics-proxy.conf   /opt/frigate/metrics-proxy.conf
pct exec 111 -- bash -c 'cd /opt/frigate && docker compose up -d'
```
Then on the Pi `./configs/pi/redeploy.sh` so Prometheus picks up the `frigate` job.

**Dashboard:** Grafana → **DNS & NVR** (AdGuard section + Frigate section).
**Verify:** Prometheus → Targets → `adguard` and `frigate` UP; `curl -s http://frigate-lxc.home.alexjenkinson.com:9101/metrics | grep frigate_ | head`.
**Caveat:** AdGuard metric names vary by exporter version — if No data, `curl -s localhost:9617/metrics | grep adguard_`.

---

## Tdarr — tdarr-exporter  ✅

**tdarr-exporter** (`homeylab/tdarr-exporter`, `:9114`) scrapes Tdarr's stats API (LXC 210 `:8265`) and
re-exposes it — Tdarr has no native metrics. No API key (Tdarr has no auth). Runs on the Pi, host
networking; its own default port is 9090 (clashes with Prometheus) so it's moved to `PROMETHEUS_PORT=9114`.
**Metrics:** `tdarr_size_diff_bytes` (space saved, signed), `tdarr_transcodes_completed`, `tdarr_files`,
`tdarr_health_check_score_ratio`, per-library `tdarr_library_*` (with `library_name`), `tdarr_library_transcodes`
(by `status` — the queue/error breakdown), `tdarr_node_worker_*`, `tdarr_server_uptime_seconds`.
**Dashboard:** Grafana → **Tdarr transcoding** (uid `tdarr`).
**Verify:** Prometheus → Targets → `tdarr-stats` UP; `curl -s http://pi.home.alexjenkinson.com:9114/metrics | grep tdarr_ | head`.
**Caveat:** empty until Tdarr has a library + has run at least once; `tdarr_size_diff_bytes` is signed
(positive = space reclaimed). If the target is DOWN, check the exporter can reach `media-pipeline…:8265`.

---

## Home Assistant — native Prometheus integration  ✅

HA exposes `/api/prometheus` (lights, sensors, climate, binary sensors, switches…) behind a bearer token
— no separate exporter container. Two steps:

**1. Enable the integration (automated).** On nuc2, one command appends the `prometheus:` block to HA's
`configuration.yaml`, validates, restarts HA and verifies — idempotent, safe to re-run:
```bash
./configs/homeassistant/ha-config.sh enable-prometheus
```
(Needs HAOS SSH set up once — `./configs/homeassistant/ha-config.sh setup-ssh`. The manual alternative
is pasting `configs/homeassistant/prometheus-snippet.yaml` into `configuration.yaml` via the File editor
add-on, then restarting HA.)

**2. Add the token.** HA → your profile (bottom-left) → **Security** → **Long-lived access tokens** →
**Create**, copy it. Then on the **Pi** put it in `.env` as `HA_TOKEN` — either via the creds wizard
(step 9, `./configs/pi/gather-exporter-creds.sh`) or this one-liner (reads hidden, no shell history):
```bash
read -rsp 'Paste HA token: ' HA && echo && \
{ grep -q '^HA_TOKEN=' /opt/pi-stack/.env \
    && sed -i "s#^HA_TOKEN=.*#HA_TOKEN=$HA#" /opt/pi-stack/.env \
    || echo "HA_TOKEN=$HA" >> /opt/pi-stack/.env; } && unset HA
```
A long-lived token **can't be minted safely in code** — it's a UI action (the scriptable route means
editing HA's auth store directly, which risks locking you out), so this one step stays manual.

**3. Deploy.** `./configs/pi/redeploy.sh` on the Pi — it writes the token to `/etc/prometheus/ha_token`
(chowned to Prometheus's uid) and the `home_assistant` scrape job reads it as a bearer.

**Dashboard:** Grafana → **Home Assistant** (Lights / Climate / Batteries & power / Waste collection /
Doors & motion).
**Verify:** Prometheus → Targets → `home_assistant` UP; `curl -s -H "Authorization: Bearer <token>" http://homeassistant.home.alexjenkinson.com/api/prometheus | grep homeassistant_ | head`.
**Tuning:**
- The **Waste collection** panel matches sensors named bin/waste/recycling/refuse that report a *number
  of days*. If your bin integration reports a *date* (non-numeric → not exported) or a different name,
  check the metric names in that `curl` and adjust the regex in `home-assistant.json`.
- The **Binary sensors** panel filters to door/motion/window/presence/leak/smoke by name — widen or
  narrow the regex to taste.
- Battery metric is `homeassistant_battery_level_percent`; if empty, your HA version may use
  `homeassistant_sensor_battery_percent` — adjust the panel.

---

## Adding another exporter later

1. Add the service to `configs/pi/docker-compose.yaml` (host networking, a free port).
2. Put any secret in `configs/pi/.env` (and document it in `.env.example`, value blank).
3. Add a scrape job to `configs/pi/prometheus/prometheus.yml`.
4. Add a dashboard JSON under `configs/pi/grafana/dashboards/`.
5. `git pull && ./configs/pi/redeploy.sh` on the Pi. Check Prometheus → Targets.



