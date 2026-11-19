# Media stack — Plex + the Arrs, explained

How the automated-media pipeline fits together: you add a title, the stack finds it, downloads it,
files it, subtitles it, and Plex serves it — then keeps itself tidy. Everything but Plex runs as Docker
Compose on **LXC 210 (`media-pipeline`)** on nuc1; Plex has its own **LXC 220**. Service map + ports:
[`services.md`](../services.md). Storage + growth: [`storage.md`](../storage.md).

## The flow, end to end

```
   you add a show/movie
          │
          ▼
  Sonarr (TV) / Radarr (film)     ──asks──▶  Prowlarr  ──▶  indexers
   the "brains": what to get,                (one place to                │ (FlareSolverr
   quality, renaming, library                 manage all                 │  solves Cloudflare
          │                                    indexers)                  │  walls)
          │ best release ──────────────────────────────────────────────┘
          ▼
   qBittorrent  ──downloads to──▶  /data/torrents
          │
          │ on complete, Sonarr/Radarr IMPORT:
          │   HARDLINK the file into /data/library (renamed + organised)
          ▼
   /data/library  ──scanned by──▶  Plex  ──serves──▶  your devices
          ▲
          └── Bazarr adds subtitles to the library
```

## The core components

| Service | Role | Port | Touches files? |
|---|---|---|---|
| **Sonarr** | TV brain — what episodes to get, quality, renaming, the TV library | 8989 | `/data` |
| **Radarr** | Film brain — same, for movies | 7878 | `/data` |
| **Prowlarr** | Indexer manager — configure your trackers/indexers **once**, it syncs them into Sonarr + Radarr | 9696 | no (config only) |
| **qBittorrent** | Download client — fetches releases into `/data/torrents`, keeps seeding | 8080 | `/data` |
| **Bazarr** | Subtitles — pulls subs for whatever's in the library | 6767 | `/data` |
| **Plex** | Media server — indexes `/data/library` and streams it (LXC 220) | 32400 | `/data/library` |

## The one design decision that makes it all work: hardlinks

`/data/torrents` (downloads) and `/data/library` (final) live under **one mount** — `/data`, the mergerfs
pool bind-mounted into the container. That's deliberate:

- **Importing is a hardlink, not a copy.** When a download finishes, Sonarr/Radarr create a second
  directory entry pointing at the *same bytes* in the library, renamed and organised. It's instant, uses
  **zero extra disk**, and qBittorrent keeps **seeding** from the original path — nothing is moved or
  duplicated.
- **Hardlinks only work within one filesystem**, so torrents + library *must* share a mount. Split them
  across two mounts and every import silently falls back to a full copy (double disk, no seeding).
- **`PUID/PGID 1000` everywhere** so every container reads/writes with the same ownership.
- mergerfs `category.create=epmfs` keeps a title's files on **one branch**, so a hardlink never has to
  cross physical disks (which would fail with `EXDEV`).

> This is why the planned NAS migration keeps the whole `/data` tree on **one NFS share** — see
> [`runbooks/nas-migration.md`](nas-migration.md).

## The supporting cast (the bit most setups don't have)

| Service | What it does |
|---|---|
| **FlareSolverr** | A headless-Chrome proxy that solves Cloudflare / anti-bot challenges for indexers that need it. Prowlarr calls it; it's the hungriest thing in the stack (1 GB). Internal-only. |
| **Recyclarr** | Syncs **TRaSH-Guides** quality profiles + custom formats into Sonarr/Radarr, so your "what counts as a good release" rules are curated-best-practice, not hand-tuned. (`recyclarr.yml`) |
| **Decluttarr** | Watches the Sonarr/Radarr queues and auto-removes **stalled, failed, or redundant** downloads so the queue never silently jams. |
| **qbit_manage** | Housekeeping for qBittorrent — categories/tags, cross-seed hardlink awareness, and cleanup of orphaned or unregistered torrents. (`qbit_manage.config.yml`) |
| **Maintainerr** | Watch-based **library cleanup** (`:6246`): rules call Radarr/Sonarr to delete big, unwatched, re-acquirable titles after a Discord-reviewed grace period. Store-less lever (`storage.md`). |
| **maintainerr-keeper** | A small Discord bot that drives Maintainerr's keep/delete review — you tag `keep` in Discord and it's spared. |
| **Tdarr** | Background transcoder (`:8265`): re-encodes the library to HEVC/AV1 (~half the size). Scratch goes on the **pool** (`/data/.tdarr_cache`), never the LXC rootfs. Store-smaller lever. |

## Where it lives & how you reach it

- **LXC 210** (nuc1) runs every box above except Plex, as one Docker Compose stack
  (`configs/media-pipeline/docker-compose.yaml`). They talk to each other by Docker **service name** on
  Compose's own network; each has a `mem_limit` and its config in `/opt/<service>/config`.
- **LXC 220** (nuc1) runs Plex alone.
- **On the LAN:** nginx gives the main apps clean HTTPS names under the `*.home.alexjenkinson.com`
  wildcard — `sonarr.home…`, `radarr.home…`, `bazarr.home…`, `prowlarr.home…`, `qbittorrent.home…`,
  `plex.home…`. Maintainerr + Tdarr are reached directly by port. ([`services.md`](../services.md))
- **From outside:** Tailscale — nothing is port-forwarded (R20).

## How it's deployed (and survives a rebuild)

Pull-only, repo-as-source-of-truth: edit the compose/config in the repo, `git pull` on nuc1,
`./configs/pi/redeploy.sh`-style `docker compose up -d` in `/opt/media-pipeline`. Secrets (API keys,
qBit password) live only in the gitignored on-box `.env` (R21) — the repo holds the shape, the seed
scripts (`arr-setup.py`, `fill-arr-keys.sh`, `recyclarr.yml`, `maintainerr-seed-rules.py`) rebuild the
wiring, and the Arr `/config` dirs restore from PBS. The **library itself is reconstructable** (R26), so
it's deliberately not backed up — the Arrs can re-fetch it.

## Mental model in one line

**Prowlarr** feeds indexers to the **Sonarr/Radarr** brains → they grab via **qBittorrent** → import by
**hardlink** into the library → **Bazarr** subtitles it and **Plex** serves it, while **Recyclarr /
Decluttarr / qbit_manage / Maintainerr / Tdarr** keep the quality high, the queue clean, and the disk
from filling.
