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
