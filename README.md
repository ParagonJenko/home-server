# home-server

Off-box source of truth for a portable, self-healing Proxmox homelab: two Beelink NUCs, a Raspberry Pi, a 2×4TB DAS and a 2TB USB HDD running media, cameras, backups, monitoring and DNS.

This repo is the thing the rebuild reads. The step-by-step runbook that drives it is the interactive page at [`docs/runbook.html`](docs/runbook.html) (open it in a browser, or serve `docs/` via GitHub Pages); this repo holds the **rules**, the **runnable configs**, and the **living docs** (network, storage, services, inventory) that those steps reference.

> **This repo is public.** No password, token, webhook or credential belongs in it — ever. Secrets live only in gitignored files on each box and in an off-box vault (see [`rules.md`](rules.md) R21). Only `*.example` templates are committed. `.gitignore` enforces this, but the discipline is yours: one accidental real value is scraped within minutes.

## The mission

Three invariants the whole build is designed around:

1. **A single workload filling up is normal and graceful; the shared system filling up is impossible.** A filesystem aborting at 100% is the one real failure, and it is designed out.
2. **Power loss pauses the system; it never corrupts it.** UPS + ordered shutdown make a yanked cable a clean stop.
3. **The whole system rebuilds from off-box state alone — secrets included.** Docs, backups and every secret live somewhere no single dead box takes with it.

The full rule set (R1–R27) is in [`rules.md`](rules.md).

## Layout

```
docs/runbook.html The interactive step-by-step runbook (snapshot of the published page)
rules.md          The guardrails — statement / why / how-to-verify, R1–R27
network.md        Addressing plan, address register (MAC/IP), DNS rewrite groups
storage.md        Disk register, per-workload caps, reserved headroom, data classification
services.md       Service map and the Nginx routing table
inventory.md      Hardware inventory
configs/          The runnable definitions (run the file; don't retype from docs)
  lxc/            Proxmox container build scripts + shared helpers (_*.sh)
  mergerfs/       Media pool fstab snippet + fill test
  media-pipeline/ qBittorrent + the Arr stack (compose + API setup)
  plex/           Plex (compose)
  nginx/          Reverse-proxy config
  frigate/        NVR (compose + config)
  pbs/            Proxmox Backup Server VM + datastore + offsite sync
  pi/             AdGuard + Prometheus + Alertmanager + Grafana (compose)
  monitoring/     Alert rules + host exporters (thin-pool, SMART)
  nut/            UPS / graceful-shutdown config
  ollama/         Local LLM inference (future, optional)
```

## Rules of the repo

- **One source of truth.** A fact about the system lives in exactly one file, updated in the *same change* as the thing it describes (R2).
- **Configs are files, not clicks.** Every service is a compose file, container script or documented build; an agent can recreate any service from its definition alone (R19).
- **Run the file, don't retype it.** The docs say which script and what it does; the script holds the real commands.
- **Keep the directory structure.** `configs/lxc/*.sh` source their siblings (`_template.sh`, `_idmap.sh`, …) by relative path — run them from the repo root.

## Bootstrap (public repo — no credentials needed)

Because the repo is public, any freshly-installed box clones it directly:

```sh
git clone https://github.com/ParagonJenko/home-server
cd home-server
# run the stage scripts as the runbook directs, e.g.:
./configs/lxc/stage-a-host-setup.sh
```

## Status

Scaffold. The `.md` docs carry the plan; the `configs/` scripts are starting points to fill in as each stage is built and verified. Record what you actually did in the doc that owns that fact — the test is whether the stack rebuilds from this repo plus PBS on hardware that has never seen it.
