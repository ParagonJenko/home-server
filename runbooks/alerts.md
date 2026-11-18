# Alert runbook — every alert, what it means, what to do

One entry per alert in `configs/monitoring/alerts.yml`. The Discord embed already carries
**Impact / What / Fix / Where** for each; this is the fuller "now what" reference.

**Severity rule:** `critical` = **act now** (a real failure or imminent data loss). `warning` =
**informational / self-healing / plan-ahead** — note it, act only if it persists or recurs. Every
alert below is tagged by that rule, so a warning you can glance at and a critical you can't.

In Discord the embed is coloured by severity (via the alert-relay): **red = critical**, **amber =
warning**, **green = resolved** — so you can tell at a glance whether one needs you.

## At a glance

| Alert | Sev | Act now? | One-line response |
|---|---|---|---|
| ThinPoolMetadataHigh | 🔴 crit | yes | Extend thin-pool metadata before it hits 100% |
| SmartFailurePredicted | 🔴 crit | yes | Confirm, then replace the disk (backups cover you) |
| InternalDNSBroken | 🔴 crit | yes | Restart/repoint AdGuard — near-total outage |
| ServiceDown | 🔴 crit | yes | Restart the guest; check it resolves |
| GatewayDown | 🔴 crit | yes | Check the router/switch/Pi link |
| InternetDown | 🔴 crit | triage | Check your modem first; else it's the ISP (wait) |
| DiskUsageHigh | 🟧 warn | plan | Clear space or raise the cap — graceful at 80% |
| PBSDatastoreFull | 🟧 warn | plan | Prune/GC runs itself; size up the disk if it recurs |
| GuestMemoryHigh | 🟧 warn | soon | Raise the guest's RAM ceiling and/or cap the greedy container |
| SmartUnreadable | 🟧 warn | usually no | Transient bridge blip; act only if 6h+ |
| DiskTempHigh | 🟧 warn | maybe | Check airflow/fans; usually cooling not the disk |
| SmartCollectorStale | 🟧 warn | soon | Re-run smartmon.sh — you're blind to SMART meanwhile |
| CameraDown | 🟧 warn | maybe | Check the camera/reservation/rewrite |
| HighLatency | 🟧 warn | no | Watch it; WAN congestion or box load |
| TLSCertExpiringSoon | 🟧 warn | no | acme.sh auto-renews; only act if it lapses |
| ProbeFailed | 🟧 warn | soon | An exporter is down — a monitoring blind spot |
| InternetSpeedLow | 🟧 warn | no | Confirm by hand; often congestion/a big download |
| SpeedtestStale | 🟧 warn | soon | Re-run speedtest.sh / check the Ookla CLI |
| ArrHealthIssue | 🟧 warn | maybe | Read the Arr's System → Status |

---

# Critical — act now

## ThinPoolMetadataHigh
Thin-pool **metadata** on a NUC is over 80%. At 100% the pool goes read-only and can be
**unrecoverable** — every LXC/VM on `local-lvm` on that node is affected. This is the alert closest
to the catastrophic failure the whole build designs out (R8).
1. `asquared ssh <nuc>`; `lvs -a` — look at `data%` and `meta%` on `pve/data`.
2. Autoextend should pre-empt this — check `/etc/lvm/lvm.conf` has `thin_pool_autoextend_threshold`/`_percent` set.
3. Extend metadata now: `lvextend --poolmetadatasize +1G pve/data`.
4. If data% is also high, the real fix is less data on that node — move a guest or grow storage (see `storage.md`).

## SmartFailurePredicted
A **readable** disk reports SMART overall-health = FAILED — genuine, not an unreadable bridge. See
[`drive-health.md`](drive-health.md).
1. Confirm: `smartctl -H -d sat /dev/<dev>` and read the attributes (reallocated/pending/offline).
2. Run a long test: `smartctl -t long -d sat /dev/<dev>`.
3. If real, replace per role (drive-health.md §4) — mergerfs pool disk, Proxmox SSD, or PBS disk.
4. Check backups first: `./configs/pbs/verify-backups.sh`.

## InternalDNSBroken
AdGuard answers on `:53` but can't resolve `*.home.alexjenkinson.com` — **near-total outage** (every
service-by-name, Frigate's cameras, Prometheus targets).
1. `asquared ssh pi`; is AdGuard up? `docker ps`, and the UI at `http://192.168.1.4:8081`.
2. Re-apply the rewrites: `asquared dns`.
3. Confirm the router's DNS is the Pi and **only** the Pi (R14) — a public secondary breaks `*.home` intermittently.
4. Test: `getent hosts pi.home.alexjenkinson.com`.

## ServiceDown
An HTTP service hasn't responded for 5m.
1. `asquared status` on its host; `asquared logs <id>`.
2. Is the guest up, and does its name resolve? `getent hosts <name>`.
3. Restart: `asquared restart <id>`. `services.md` maps the name → host/guest/port.

## GatewayDown
The LAN gateway `192.168.1.1` is unreachable for 2m — likely a LAN-wide outage.
1. Is the router powered and up? Check the switch and the Pi's own link.
2. If the Pi lost its network, **every** probe fails — check whether `ProbeFailed` is also firing.
3. Power-cycle the router/switch if needed; the stack returns on its own (R18).

## InternetDown
ICMP to `1.1.1.1` has failed for 3m — WAN/upstream is gone. **Triage, don't panic:** the action is to
rule out your side, then it's the ISP's problem (wait).
1. Is `GatewayDown` also firing? If yes, it's a LAN issue, not WAN — fix that first.
2. If only InternetDown: check the modem/ONT; reboot it; check the ISP status page.
3. Nothing local to fix beyond the modem — Tailscale/remote access is down until the WAN returns.

---

# Warning — note it, act only if it persists

## DiskUsageHigh
A filesystem is over 80% full. Graceful by design (R7) — a heads-up, not an emergency.
`asquared ssh <host>` → `df -h <mount>`; clear space or raise the cap (local-lvm ceilings / mergerfs
`minfreespace` in `storage.md`). Media pool filling is expected; the Arrs pause at their floor.

## PBSDatastoreFull
The backup datastore is over 85%. Prune/GC (keep-daily 7 / weekly 4 / monthly 6) runs automatically.
Act only if it recurs: on PBS run `proxmox-backup-manager garbage-collection start <datastore>`, or size
up the USB HDD (`storage.md`). Offsite B2 is the deeper copy.

## GuestMemoryHigh
A VM or LXC is over **90%** of its RAM allocation for 15m. Left alone it starts swapping, and
swap-thrash is self-reinforcing — the services inside slow to a crawl and start timing out (the
media-pipeline 504s came from exactly this: a 2 GB cap for the whole Arr stack). Act before it thrashes.

**Diagnose** (on the guest's host, from the alert's `id` e.g. `lxc/210`):
```bash
pct config 210 | grep -E 'memory|swap'                 # the current ceiling
pct exec 210 -- free -h                                 # used vs free + swap
pct exec 210 -- docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}'
free -h                                                  # does the HOST have RAM to give?
```

**Fix — pick based on what you found:**
1. **Ceiling too low + host has RAM** → raise it (applies live; restart the apps to clear the thrash):
   ```bash
   pct set 210 --memory 6144 --swap 2048
   pct exec 210 -- sh -c 'docker restart $(docker ps -q)'
   ```
2. **One container is the hog** → cap it in its compose (`mem_limit: 1g`) so it can't starve the rest
   (the proper R6/R9 guardrail), then `docker compose up -d` that container.
3. **Host itself is out of RAM** → don't over-commit; cap the greediest services instead, or move a
   guest to the other node.

**Then make it permanent** so a rebuild doesn't recreate the trap: update the guest's `--memory` in its
create script (e.g. `configs/lxc/media-pipeline.sh`) and record the size in `storage.md`.

## SmartUnreadable
`smartctl` couldn't read a disk through its USB/DAS bridge — a **flag/cable** issue, **not** a failing
disk. smartmon.sh retries and the alert only fires after **6h** of continuous unreadability, so this
means a persistent bridge fault. `smartctl --scan-open` for the right `-d`, reseat the cable. See
[`drive-health.md`](drive-health.md) §0. Health failures alert separately (SmartFailurePredicted).

## DiskTempHigh
A drive is over 60°C for 15m. Usually airflow/cooling, not the disk. Check fans around the box/DAS,
ambient temp, and whether a scrub/backup/SMR write-storm is hammering it.

## SmartCollectorStale
`smartmon.sh` stopped writing on a host (>1h) — you're **blind to disk health** there until it's back.
`asquared ssh <host>`; run `/usr/local/bin/smartmon.sh` by hand; check `crontab -l` has the 15-min entry
and that `smartmontools`+`jq` are installed. (`monitoring-exporters.md` / `drive-health.md` §5.)

## CameraDown
A camera's RTSP port `:554` has been unreachable for 10m — Frigate has probably lost that stream.
Camera powered/online? Reservation + AdGuard rewrite set? `getent hosts cam-*...` from inside LXC 111.
See [`cameras.md`](cameras.md) troubleshooting.

## HighLatency
ICMP RTT to a box/gateway over 150ms for 10m. If internet/gateway: WAN congestion or Wi-Fi backhaul.
If a box: its load or link. Watch the latency graph (Network & Uptime); self-resolves when load drops.

## TLSCertExpiringSoon
The `*.home` wildcard cert expires in under 14 days. acme.sh auto-renews via Cloudflare DNS-01 — no
action unless it lapses. Force: on nginx LXC 240, `acme.sh --renew -d '*.home.alexjenkinson.com' --force`;
check the Cloudflare API token (R21).

## ProbeFailed
Prometheus can't scrape an exporter (`up == 0`) — a **monitoring blind spot** on that target, and its
own alerts can't fire. `asquared ssh <instance>`: `systemctl status prometheus-node-exporter` (NUCs) or
`docker ps` (Pi); check the port. If it's an app exporter, see `monitoring-exporters.md`.

## InternetSpeedLow
Ookla download is below the configured floor for 1h. Confirm by hand (`speedtest` on the Pi); check for
a big download (qBittorrent) or congestion; reboot the router. Tune the threshold in `alerts.yml` to
~50% of your plan once you've seen a baseline.

## SpeedtestStale
`speedtest.sh` hasn't written a result in over 3h. `asquared ssh pi`; run `/usr/local/bin/speedtest.sh`;
check `crontab -l` has the 2h entry and the Ookla CLI is installed (`speedtest --version`).

## ArrHealthIssue
Sonarr/Radarr/Prowlarr is self-reporting a health problem (indexer down, download client unreachable,
root folder missing, update available…). Open the app → System → Status to read it:
`https://<app>.home.alexjenkinson.com`.

---

## Adding a new alert

Every rule in `configs/monitoring/alerts.yml` carries five annotations — `summary`, `impact`, `cause`,
`fix`, `where` — which the Discord template renders. When you add an alert, fill all five and add a
section here, tagged by the severity rule at the top (critical only if it needs action now).
