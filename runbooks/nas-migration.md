# NAS migration — build a TrueNAS SCALE box and cut the media pool over to it

Moves the media pool (and general file storage) off the USB DAS — mergerfs on nuc1 — onto a
dedicated **TrueNAS SCALE** box, network-attached over NFS. The decision, target layout and parts
live in [`storage.md` → *Planned: NAS migration*](../storage.md); this is the do-it procedure.

**Golden rule: the DAS is the rollback.** rsync only ever *reads* from `/mnt/media`, and the mergerfs
pool stays mounted and untouched until the migration is verified for a few days. Don't wipe the 2×4 TB
disks until then.

---

## 0. Prerequisites

- Hardware assembled per the chosen tier in `storage.md`. Any **HBA flashed to IT mode** (not RAID).
- A **reserved IP + DNS name** for the box (R13): pick a free address, add a row to `network.md`'s
  Address register and put `nas.home.alexjenkinson.com` in **DNS group 3** (hosts → own IP), then on
  the Pi: `python3 configs/pi/adguard-rewrites.py --apply`. Reserve the MAC→IP on the router.
- Know the current bind: the host mergerfs pool is `/mnt/media`, bind-mounted into **LXC 210**
  (media-pipeline) and **LXC 220** (Plex) as **`/data`** (`/data/torrents` + `/data/library`).

## 1. Assemble + BIOS

Fit the disks and HBA. In BIOS: enable the HBA, boot order → the boot SSD, **power-on after AC loss**
(pairs with onboot so it returns after an outage, R22). Leave VT-d off (no passthrough needed).

## 2. Install TrueNAS SCALE

- Write the installer to USB (Etcher / `dd`), boot it, install to the **boot SSD** — never a pool disk.
- First boot: set a strong admin password → **password manager, not the repo** (R21).
- Networking: leave TrueNAS on **DHCP** and reserve its MAC→IP on the router (R13 — addressed by name,
  like every other host). Confirm `nas.home.alexjenkinson.com` resolves.

## 3. Create the pool — topology decision

Pick **one** (you can't convert without rebuilding the pool; see `storage.md`):
- **Mirror** (recommended start): 2 disks = 1 vdev; grow by adding pairs, any size, fast resilver.
- **RAIDZ2**: 6-disk endgame; space-efficient, survives 2 failures.

Storage → Create Pool (name e.g. `tank`). Keep `lz4` compression (default). **Record every disk by its
`ata-…_<serial>` by-id into `storage.md`'s register (R9)** and label the physical bays.

## 4. Datasets

- `tank/data` — the **whole** media tree in one dataset, so `/data/torrents` + `/data/library` share
  one filesystem (the Arr hardlink/atomic-move flow breaks if they're split). `atime=off` here.
- `tank/files`, `tank/photos`, … — general + irreplaceable data; these get snapshots + off-box
  replication (R26).
- Create a dedicated **`apps` uid/gid** (e.g. `3000:3000`) that matches what the LXCs write as, so NFS
  ownership lines up.

## 5. NFS export

- Sharing → Unix (NFS) Shares → add `tank/data`.
- **Allowed networks:** tighten to nuc1's IP (or the LAN /24).
- **Maproot/mapall → the `apps` uid/gid** — this is the unprivileged-LXC id-mapping gotcha: map the
  share so the container writes land with consistent ownership. Document the scheme chosen.
- Start the NFS service. NFSv4 (better perms) or v3 (simpler) — **note which** in `storage.md`.

## 6. Mount on nuc1 + bind into the LXCs

- On the **nuc1 Proxmox host**, mount the export at a NEW path (not over `/mnt/media` yet) via
  `/etc/fstab`, with **`nofail,x-systemd.device-timeout=30s`** so a NAS outage can't hang boot (same
  discipline as the DAS, R9):
  ```
  nas.home.alexjenkinson.com:/mnt/tank/data  /mnt/nas-data  nfs  _netdev,nofail,x-systemd.device-timeout=30s  0 0
  ```
  `systemctl daemon-reload && mount /mnt/nas-data`
- Leave the mergerfs `/mnt/media` → `/data` bind in place for now (rollback). The NAS lives at
  `/mnt/nas-data` during the copy.

## 7. Migrate the data (hardlink-preserving)

- Initial pass, everything still live (hours):
  ```
  rsync -aHAX --info=progress2 /mnt/media/ /mnt/nas-data/
  ```
  `-H` preserves **hardlinks** (critical), `-A -X` carry ACLs/xattrs. Re-run a couple of times — it
  only copies deltas.
- **Cutover:** stop the Arrs + qBittorrent + Plex (or `pct stop 210 220`), run a final
  `rsync -aHAX --delete /mnt/media/ /mnt/nas-data/`, then repoint the LXC binds from the mergerfs path
  to the NAS path. Edit the mountpoint line in `/etc/pve/lxc/210.conf` and `220.conf` (check the current
  `mpN:` entry) so `mp=/data` now points at `/mnt/nas-data`, then `pct start 210 220`.

## 8. Verify (acceptance checklist)

- [ ] **Hardlinks survived:** in LXC 210, `find /data -links +1 | head` lists files; a grab and its
      library copy share an inode (`ls -li`).
- [ ] **Arrs hardlink, not copy:** trigger a manual import/preview on a recent grab — no duplicate space used.
- [ ] **Plex** scans the library and plays + transcodes (scratch still local).
- [ ] **Writes work:** no permission-denied in the Arr/qBit logs (id-mapping correct).
- [ ] Pool healthy: `zpool status` clean; a **scrub** scheduled.

## 9. Move the PBS datastore onto the NAS

Create `tank/pbs` (bigger than the 2 TB USB drive — the tighter constraint today), add it as a PBS
datastore, retarget the backup jobs, **verify a restore (R4)**, then retire the USB drive.

## 10. Decommission the DAS

Only after a few clean days. Unmount mergerfs, remove its `/etc/fstab` lines, and repurpose the
2×4 TB — best as an **offsite/cold backup target** (mixing 4 TB into a large-disk pool wastes space).

## Reproducibility (don't skip — this is the whole point of the repo)

- **TrueNAS config:** System → General → Save Config. The config DB can contain secrets — treat it like
  `.env`: keep the encrypted export in the password manager, and commit a **plaintext description**
  (pool topology, datasets, share + maproot scheme, NFS version) to `storage.md`.
- **Disk register:** every NAS disk by `ata-…_<serial>` in `storage.md` (R9).
- **Snapshots + replication:** periodic snapshots on the irreplaceable datasets, replicated **off-box**
  (old DAS / another ZFS / cloud) for 3-2-1 (R26).
- **DNS/network:** `nas.home.alexjenkinson.com` recorded in `network.md` + applied via `adguard-rewrites.py`.

## Rollback

Until the DAS is wiped: `pct stop 210 220`, repoint the `mpN:` lines in the `.conf`s back to
`/mnt/media`, `pct start`. The mergerfs pool was only ever read from, so it's intact.
