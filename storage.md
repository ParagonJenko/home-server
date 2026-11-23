# storage.md

Owns which physical disk is which, every workload's disk ceiling, the reserved headroom, the fill-test results, and the data classification. `/dev/sdX` letters reorder across reboots — identify disks by `by-id` only.

## Disk register

| Disk | Host | Model / serial | `by-id` path | Role |
|---|---|---|---|---|
| Internal SSD | nuc1 | 512GB SSD / MQ13W07504681 | `ata-512GB_SSD_MQ13W07504681` | Proxmox root + `local-lvm` |
| Internal SSD | nuc2 | TBD | TBD | Proxmox root + `local-lvm` (Frigate's 260G lives here) |
| DAS disk 1 | nuc1 | ST4000DM004 / ZFN5Q3VL | `ata-ST4000DM004-2U9104_ZFN5Q3VL` | mergerfs branch → `/mnt/pool/disk1` |
| DAS disk 2 | nuc1 | ST4000DM004 / ZW63SHWZ | `ata-ST4000DM004-2U9104_ZW63SHWZ` | mergerfs branch → `/mnt/pool/disk2` |
| 2TB USB HDD | nuc2 | TOSHIBA MQ04UBD200 / 56KQP05LT | `ata-TOSHIBA_MQ04UBD200_56KQP05LT` | PBS datastore, passed to VM 900 as a block device |

> The DAS is a USB enclosure, so each DAS disk also exposes a position-based `usb-External_USB3.0_…-0:0` / `-0:1` path. Record and use the `ata-…_<serial>` by-id — it follows the disk, not the bay (R9). Both disks are the same model, so the serial is the only thing telling them apart.

## Per-workload ceilings (R6)

The sum of local-lvm LV caps on each SSD must be under SSD size minus ~10% headroom (checked at B5).

| Workload | Device | Cap | Degradation at full (R7) |
|---|---|---|---|
| media-pipeline (LXC 210) rootfs | nuc1 local-lvm | 20 G | — |
| plex (LXC 220) rootfs | nuc1 local-lvm | 32 G | Stops importing, keeps serving |
| amp (LXC 230) rootfs | nuc1 local-lvm | TBD G | — |
| nginx (LXC 240) rootfs | nuc1 local-lvm | TBD G | — |
| property-finder (LXC 260) rootfs | nuc1 local-lvm | 16 G | SQLite writes fail; scrapes stop, UI keeps serving |
| frigate (LXC 111) rootfs | nuc2 local-lvm | 260 G | Prunes oldest (14-day motion retention) |
| pbs (VM 900) system disk | nuc2 local-lvm | 16 G | — |
| homeassistant (VM 910) system disk | nuc2 local-lvm | 32 G | — |
| Downloads (`/data/torrents`) | mergerfs pool | mergerfs `minfreespace` | qBittorrent pauses; Arrs stop grabbing (Min Free Space) |
| Media library (`/data/library`) | mergerfs pool (~7.2T) | mergerfs `minfreespace` | — |
| PBS datastore | USB HDD (2T) | retention: keep-daily 7, keep-weekly 4, keep-monthly 6 + prune/GC | Oldest pruned |

## Guest RAM ceilings

`--memory`/`--swap` per guest (set in each create script). The sum must stay under each node's RAM
(nuc1 has 15 GB). Per-service `mem_limit`s inside a stack sit *under* its LXC ceiling.

| Guest | RAM | Swap | Notes |
|---|---|---|---|
| media-pipeline (LXC 210) | **6 GB** | 2 GB | Was 2 GB — too tight for the 6-service Arr stack; a spike (Bazarr scan / FlareSolverr Chrome) swap-thrashed into 504s (2026-11-18). `GuestMemoryHigh` alert (>90%) now catches it early. |
| property-finder (LXC 260) | 1.5 GB | 1 GB | Scraper's headless Chromium is the spike (every 6 h). nuc1 total with 210/220/230/240: ~12 GB of 15 — ceilings, not reservations, but watch `GuestMemoryHigh`. |

Other guests keep their defaults until a `GuestMemoryHigh` alert says otherwise — raise + record here.

## Reserved headroom (R8)

- ext4 reserved-blocks ≥5% on host root and container storage — **read the live value** (`tune2fs -l`), don't assume.
- mergerfs `minfreespace` set on the media pool (see `configs/mergerfs/fstab-snippet`).
- LVM-thin metadata volume: autoextend on (`thin_pool_autoextend_*` in `/etc/lvm/lvm.conf`), monitored by `configs/monitoring/check-thinpool.sh`.

## Fill-test results (R10)

| Filesystem | Date | Result | Notes |
|---|---|---|---|
| mergerfs pool (`/mnt/media`) | 2026-11-16 | PASS | B3 `--quick` (minfreespace raised then restored): refused at ~70G with graceful ENOSPC, pool stayed mounted, zero corruption, floor restored to 250G |
| local-lvm (throwaway LV) | 2026-11-16 | PASS | B5 `./configs/verify.sh B5`: full 5G LV refused writes (ENOSPC), host root stayed writable. Ceiling sum ~0 (no container LVs yet) — re-check after Stage G |

## Data classification (R26)

| Class | Data | Backup standard |
|---|---|---|
| **Irreplaceable** | container configs, Plex metadata, photos, documents | Full offsite 3-2-1 (PBS + G6 cloud sync) |
| **Reconstructable** | the media library, model weights | Lighter / excluded by choice — the Arrs/Ollama can re-fetch |

**Excluded from PBS:** Frigate's recording volume (260G of 14-day churn would overrun the 2TB datastore — back up Frigate's config, not its clips) and Ollama model weights.

## Managing library growth

The ~7.2 TB pool (2×4 TB mergerfs, no parity) fills over time. Three levers, in combination:

1. **Grow the pool (R1)** — add a bigger drive as a new mergerfs branch; no data moves, nothing reconfigures. Cheapest, because the library is reconstructable (R26) so it needs no backup.
2. **Store less — [[Maintainerr]]** (LXC 210, `:6246`): watch-based cleanup rules call Radarr/Sonarr to remove files, Discord-reviewed. Seed them with `configs/media-pipeline/maintainerr-seed-rules.py` (dry-run by default, `--apply` to create; resolves property/library IDs from the live instance). Per library it makes two groups: a **Clear** group (big + unwatched + released within 6 yr → auto-delete after a 7-day grace, Discord-warned) and a **Review** group (same but released 6 yr+ ago → *never* auto-deletes, only raised in Discord to tag `keep`). The age split is deliberate — old/rare titles are harder to re-acquire (R26 is weakest there), so they get a human decision, not a delete. Gates on file size (>15 GB), so small rare files are left alone, and honours a `keep` tag (Radarr/Sonarr) or a Maintainerr exclude. Needs a Discord notification configured in Maintainerr first. `--shows` adds the same for TV, additionally requiring the series to have ended.
3. **Store it smaller — [[Tdarr]]** (LXC 210, `:8265`): re-encodes the library to HEVC/AV1 (~half the size) in the background. CPU-bound here (no GPU passthrough on LXC 210 yet; 2 cores → keep to one worker and run off-peak). Scratch goes on the pool, not the rootfs.

Early warning: `DiskUsageHigh` at 80% + mergerfs `minfreespace` (hard stop — Arrs pause grabbing) mean you get a nudge with runway, never a silent 100%.

## Planned: NAS migration (future)

**Decision (2026-11-19):** move the media pool *and* general file storage off the USB DAS onto a
dedicated DIY NAS running **TrueNAS SCALE** (ZFS), network-attached. Drivers: SATA reliability over
the flaky USB DAS; real redundancy (recover on a single/double drive failure); store more than media;
expand with bigger disks over time; decouple storage from nuc1. Irreplaceable data is backed up to
PBS + offsite regardless (R26), so ZFS integrity is a bonus here, not the load-bearing reason.

**Why ZFS/TrueNAS over unRAID:** real-time parity + snapshots + replication, and TrueNAS config
exports to a file we commit — so the "rebuild from catastrophe" story holds (disks + a config file,
not a hand-built appliance).

**Run plain TrueNAS SCALE, not HexOS.** HexOS is a $199–299/server paid layer *on top of* TrueNAS
SCALE for an easier UI + remote management, but it carries a cloud-auth/identity dependency (even
local access routes through its managed flow) and is still maturing — mid-2026 reviews steer
technical DIY builders to vanilla TrueNAS for control + maturity. Since the whole homelab is
hand-scripted, the hand-holding HexOS sells isn't needed, and vanilla TrueNAS is free and
git-documentable. HexOS is TrueNAS underneath, so it stays a safe fallback if the UI ever appeals.

**Target layout:**
- Dedicated NAS box, **6–8 bays** (room to grow). **RAIDZ2** at 5+ disks, RAIDZ1 at 3–4.
- **One NFS export** holding the whole `/data` tree — `/data/torrents` + `/data/library` on the SAME
  share (the Arr hardlink/atomic-move flow needs one filesystem; it survives over NFS within one export).
- NFS-mounted on the nuc1 Proxmox host, bind-mounted into LXC 210 (media-pipeline) and 220 (Plex) at
  the SAME paths, replacing the mergerfs `/mnt/media` bind. Transcode scratch stays on local SSD.
- A larger **PBS datastore** also lives on the NAS — the 2 TB USB PBS drive is the tighter constraint
  today than the media pool.
- The 2×4 TB DAS disks retire into the NAS as pool members, or the DAS is kept as a cold/offsite copy.

**Migration order:** build + TrueNAS install → create pool + dataset → NFS export → mount on nuc1 +
bind into the LXCs at the same paths → `rsync /mnt/media/ → /data/` → stop Arrs/Plex, final rsync,
cut the binds over → verify hardlinks (`find /data -links +1`) + a test import → move/grow PBS →
decommission or repurpose the DAS. Record every NAS disk by `ata-…_<serial>` in the register above.

**Gotchas:** unprivileged-LXC NFS id-mapping (map the share uid/gid to the container); NFS not SMB for
Linux→Linux; ZFS sizes a RAIDZ vdev to its smallest disk (plan disk sizes, or use RAIDZ expansion to
add one at a time); snapshot + replicate the irreplaceable datasets off-box.

**Reference build (ex-disks):** 6–8 bay case (Jonsbo N3 / Fractal Node 804), mATX/mini-ITX board with
6+ SATA or an LSI HBA in IT mode, low-power CPU (Plex transcoding stays on nuc1, so the NAS CPU can be
modest), 16–32 GB RAM, small boot SSD. Disks: start with a large-disk **mirror** (grow by pairs) or a
6-disk **RAIDZ2** endgame. Recertified enterprise disks are the value play (data is backed up). Price
to budget before buying.

**Build + migration procedure:** [`runbooks/nas-migration.md`](runbooks/nas-migration.md) — assemble →
install TrueNAS → pool/dataset/NFS → mount + bind into LXC 210/220 → hardlink-preserving rsync cutover
→ verify → move PBS → decommission the DAS, with a rollback that keeps the DAS intact until verified.
