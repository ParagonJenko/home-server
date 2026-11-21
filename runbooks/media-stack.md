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

## Tuning & hardening (why the pool isn't on fire)

The media disks are a **USB-attached DAS**, which has a low ceiling for *concurrent random* I/O.
Two things keep it from saturating (both set by `arr-setup.py --apply`, so they survive a rebuild):

- **Hardlinks on import** (`copyUsingHardlinks=true` on Sonarr + Radarr). An import is an instant
  hardlink from `/data/torrents` to `/data/library` — same bytes, no copy, qBit keeps seeding. Pinned
  in the repo so it can't drift to copying (which would double disk use *and* I/O). Verified working
  2026-11-19 — mergerfs hardlinks fine within a branch.
- **qBittorrent seeding caps.** Seeding many torrents at once is a random-read storm the USB DAS can't
  take (it was pushing nuc1 to ~80% IO-delay with 15 active). So: queueing on, **3 active torrents**,
  **"don't count slow torrents" OFF** (so the limit actually bites — idle seeders were bypassing it),
  trimmed connections/upload-slots, and a **ratio-2 / 14-day** seed limit that pauses finished torrents.

Neither is a real fix for the USB ceiling — that's the **NAS migration** (ZFS ARC caches hot pieces in
RAM, and a single pool means hardlinks are never even in question). See `../storage.md`.

## Running `arr-setup.py` (seed/repair the wiring)

`arr-setup.py` configures the stack over the app APIs (root folders, qBit client + categories,
Prowlarr apps, hardlink pin, qBit seeding caps, Bazarr connections + English profile + subtitle
auto-sync, Forms auth). It's **idempotent** and dry-run by default.

It must run **inside LXC 210** (that's where the APIs are on `localhost` and Bazarr's `config.yaml`
is on disk). From the Proxmox host (`nuc1`), use the wrapper — it `pct exec`s into the container for
you, so there's nothing to configure:

```bash
cd ~/home-server
# first time only: fill in API keys + qBit password (prompts, saves to the gitignored .env)
python3 configs/media-pipeline/arr-setup.py            # on the host; API calls fail on localhost
                                                        # but the keys get saved — that's all this is for
# then run it for real, inside the container:
./configs/media-pipeline/run-arr-setup.sh              # dry run in LXC 210
./configs/media-pipeline/run-arr-setup.sh --apply      # write
```

The wrapper stages `.env` into the container, runs there, pulls back any keys the run generated, and
cleans up. `.env` stays on the host (gitignored, source of truth). Override the container id with
`MEDIA_CTID=NNN` if 210 ever changes. Needs `python3` in the LXC (`apt-get install -y python3` if not).

> Running it straight on the host instead works too, but then you must set `SONARR_URL` /
> `RADARR_URL` / `PROWLARR_URL` / `QBIT_HOST` / `BAZARR_URL` + `BAZARR_API_KEY` in `.env` to reach
> the LXC over the LAN. The wrapper avoids all of that.

## Subtitles (Bazarr) — auto-sync

Bazarr fetches subs for the library and **auto-syncs** them. `arr-setup.py` turns on ffsubsync
(Bazarr → Settings → Subtitles → *Automatic Subtitles Synchronization* → "Automatically sync all
subtitles after download"), which aligns every downloaded subtitle to the **audio track** — fixing a
constant offset *and* the 23.976-vs-25fps framerate drift that makes UK releases' subs run ahead or
behind. Pinned in the repo (`settings-subsync-*`) so a rebuild keeps it.

- **New downloads** are synced automatically on the way in.
- **Already out-of-sync subs**: re-sync in place via Bazarr → the series/movie → the subtitle row →
  **Tools → Sync** (there's a mass-select too), or delete the sub and let it re-download — auto-sync
  catches it. ffsubsync needs ffmpeg, which is bundled in the Bazarr image.
- **Set it by hand** if the `arr-setup.py` Bazarr step ever fails (its settings API is fussy and can
  500): Bazarr → Settings → Subtitles → *Automatic Subtitles Synchronization* → turn on **"Automatically
  sync all subtitles after download"** → Save. Same setting, 10 seconds.

### Score threshold — sync-all vs surgical

The sync is set to **sync all** downloaded subs (threshold off), which is what `arr-setup.py` pins
(`settings-subsync-use_subsync_threshold=false`, `settings-subsync-use_subsync_movie_threshold=false`).
ffsubsync barely changes a sub that's already in time, so sync-all is the simplest and most reliable
setting, and on this box the extra CPU is trivial.

To only sync the uncertain ones instead, turn on the **Series/Movies Score threshold** and set both to
**96%**:

- The threshold is a **percentage of the subtitle's match score** (series scored out of 360, movies out
  of 120) and means "only sync subs scoring *below* this".
- A near-perfect match (hash / exact-release) is already byte-aligned to the file, so it's already in
  time. 96% leaves those alone and syncs everything less certain — which is the stuff that actually
  drifts. Either way fixes out-of-sync subs; sync-all just also re-times the already-good ones (harmless).

## No subtitle exists? Generate it (Whisper)

When no provider has a subtitle (or you don't want to pay for one), the **whisper** service transcribes
the **audio track** into a subtitle. It's free, runs locally, and — because the text is timed to the
actual audio — the result is **in sync by construction**, so it also sidesteps the out-of-sync problem
entirely for anything it makes. Bazarr's built-in **`whisperai`** provider drives it.

- **How it fits**: Whisper is a **last-resort** provider (low score), so Bazarr only uses it when the
  normal providers come up empty. English audio → English subs; non-English audio → it can translate to
  English. It runs on a missing-sub search (automatic or manual).
- **Where it runs**: `whisper` container in the LXC 210 compose, reached at `http://whisper:9000` over
  the compose network (no host port). CPU-only — there's no GPU on this unprivileged LXC.
- **Model knob** (`docker-compose.yaml` → `whisper` → `ASR_MODEL`): `tiny < base < small < medium <
  large-v3`. Default **`small`** (the CPU sweet spot). Drop to `base` if the NUC struggles next to Tdarr/
  the Arrs; raise to `medium` for quality if you can wait. The model downloads once into
  `/opt/whisper/cache` and persists. A 45-min episode on `small`/CPU is minutes, not seconds — it's a
  background job, not instant.
- **Pinned in the repo**: the service is in `docker-compose.yaml`; `arr-setup.py` enables the provider
  (`settings-whisperai-*`) and **appends** `whisperai` to your enabled providers without wiping any free
  ones you already have.
- **Set it by hand** if the `arr-setup.py` Bazarr step 500s: Bazarr → Settings → Providers → **add
  Whisper** → Endpoint `http://whisper:9000` → Save; then Settings → Subtitles and make sure your
  language profile is applied. Then re-search a title with no sub.

### Deploy (pull-only boxes)

From `root@nuc1`, after `git pull`:

```bash
pct push 210 configs/media-pipeline/docker-compose.yaml /opt/media-pipeline/docker-compose.yaml
pct exec 210 -- docker compose -f /opt/media-pipeline/docker-compose.yaml up -d whisper   # pulls model on first run
pct exec 210 -- ls /opt/whisper/cache 2>/dev/null   # (docker creates the bind dir; model lands here)
```

Then apply the Bazarr wiring with the usual wrapper (runs `arr-setup.py` inside LXC 210):

```bash
configs/media-pipeline/run-arr-setup.sh --apply
```

**Already-wrong / missing subs on existing files**: trigger a fresh search in Bazarr (per-item, or the
mass-edit → *Search* ) — found subs get auto-synced, and anything still missing gets a Whisper sub.

## Mental model in one line

**Prowlarr** feeds indexers to the **Sonarr/Radarr** brains → they grab via **qBittorrent** → import by
**hardlink** into the library → **Bazarr** subtitles it and **Plex** serves it, while **Recyclarr /
Decluttarr / qbit_manage / Maintainerr / Tdarr** keep the quality high, the queue clean, and the disk
from filling.
