# storage.md

Owns which physical disk is which, every workload's disk ceiling, the reserved headroom, the fill-test results, and the data classification. `/dev/sdX` letters reorder across reboots — identify disks by `by-id` only.

## Disk register

| Disk | Host | Model / serial | `by-id` path | Role |
|---|---|---|---|---|
| Internal SSD | nuc1 | TBD | TBD | Proxmox root + `local-lvm` |
| Internal SSD | nuc2 | TBD | TBD | Proxmox root + `local-lvm` (Frigate's 260G lives here) |
| DAS disk 1 | nuc1 | TBD | TBD | mergerfs branch → `/mnt/pool/disk1` |
| DAS disk 2 | nuc1 | TBD | TBD | mergerfs branch → `/mnt/pool/disk2` |
| 2TB USB HDD | nuc2 | TBD | TBD | PBS datastore, passed to VM 900 as a block device |

## Per-workload ceilings (R6)

The sum of local-lvm LV caps on each SSD must be under SSD size minus ~10% headroom (checked at B8).

| Workload | Device | Cap | Degradation at full (R7) |
|---|---|---|---|
| media-pipeline (LXC 210) rootfs | nuc1 local-lvm | TBD G | — |
| plex (LXC 220) rootfs | nuc1 local-lvm | 32 G | Stops importing, keeps serving |
| amp (LXC 230) rootfs | nuc1 local-lvm | TBD G | — |
| nginx (LXC 240) rootfs | nuc1 local-lvm | TBD G | — |
| frigate (LXC 111) rootfs | nuc2 local-lvm | 260 G | Prunes oldest (14-day motion retention) |
| pbs (VM 900) system disk | nuc2 local-lvm | 16 G | — |
| Downloads (`/data/torrents`) | mergerfs pool | mergerfs `minfreespace` | qBittorrent pauses; Arrs stop grabbing (Min Free Space) |
| Media library (`/data/library`) | mergerfs pool (~7.2T) | mergerfs `minfreespace` | — |
| PBS datastore | USB HDD (2T) | retention: keep-daily 7, keep-weekly 4, keep-monthly 6 + prune/GC | Oldest pruned |

## Reserved headroom (R8)

- ext4 reserved-blocks ≥5% on host root and container storage — **read the live value** (`tune2fs -l`), don't assume.
- mergerfs `minfreespace` set on the media pool (see `configs/mergerfs/fstab-snippet`).
- LVM-thin metadata volume: autoextend on (`thin_pool_autoextend_*` in `/etc/lvm/lvm.conf`), monitored by `configs/monitoring/check-thinpool.sh`.

## Fill-test results (R10)

| Filesystem | Date | Result | Notes |
|---|---|---|---|
| mergerfs pool (`/mnt/media`) | TBD | TBD | B6 — writes 50G blobs until refusal, graceful stop, zero corruption |
| local-lvm (throwaway LV) | TBD | TBD | B8 — full LV goes read-only, host stays up |

## Data classification (R26)

| Class | Data | Backup standard |
|---|---|---|
| **Irreplaceable** | container configs, Plex metadata, photos, documents | Full offsite 3-2-1 (PBS + E7 cloud sync) |
| **Reconstructable** | the media library, model weights | Lighter / excluded by choice — the Arrs/Ollama can re-fetch |

**Excluded from PBS:** Frigate's recording volume (260G of 14-day churn would overrun the 2TB datastore — back up Frigate's config, not its clips) and Ollama model weights.
