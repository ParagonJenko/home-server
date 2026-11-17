# Drive health, testing & replacement

What to do when a SMART alert fires, when a drive sounds or behaves wrong, and how to replace a
dead one. The monitoring (`configs/monitoring/smartmon.sh` → Prometheus → the **Disks & SMART**
dashboard + Discord alerts) tells you *something* changed; this runbook tells you whether it's real
and what to do.

**First principle: identify disks by `by-id`, never `/dev/sdX`.** The letters reorder across reboots.
`storage.md` holds the register (model, serial, `ata-…_<serial>` path, role). Both DAS disks are the
same model — the **serial** is the only thing telling them apart.

## 0. Is the alert even real? (the unreadable-vs-failed trap)

Tonight's lesson, baked into the tooling: **"can't read SMART" is not "SMART failed."** USB/DAS disks
need the right `-d` flag (`sat`, `nvme`, …) or `smartctl` can't read them through the bridge. The
exporter now reports these as two different signals:

| Signal | Metric | Alert | Means |
|---|---|---|---|
| **FAILED** | `smartmon_device_smart_healthy == 0` | `SmartFailurePredicted` (critical) | A readable disk reports SMART failure — act. |
| **UNREADABLE** | `smartmon_device_smart_readable == 0` | `SmartUnreadable` (warning) | `smartctl` couldn't read it — a flag/bridge issue, **not** a verdict on the disk. |

If you get a flood of criticals right after a monitoring change, suspect the reader, not the disks.
Confirm by hand:

```bash
smartctl --scan-open                 # shows the -d flag smartctl recommends per device
smartctl -H -d sat /dev/sdX          # overall health; "PASSED" = fine
```

## 1. Read the real health (attributes, not just the pass/fail flag)

The overall `-H` flag is blunt. For anything suspicious — a noise, a slowdown, an alert — read the
attributes (DAS disks need `-d sat`):

```bash
smartctl -A -d sat /dev/sdX | grep -iE \
 'Reallocated_Sector|Current_Pending|Offline_Uncorrectable|Reported_Uncorrect|Spin_Retry|Command_Timeout|UDMA_CRC|Load_Cycle|Temperature'
```

| Attribute | Healthy | What a bad value means |
|---|---|---|
| `Reallocated_Sector_Ct` (5) | 0 | Sectors remapped — **>0 and rising = dying.** A few stable is tolerable; trend is what matters. |
| `Current_Pending_Sector` (197) | 0 | Unreadable sectors awaiting remap — **>0 = act, run a long test.** |
| `Offline_Uncorrectable` (198) | 0 | Confirmed bad sectors. |
| `Reported_Uncorrect` (187) | 0 | Errors the drive couldn't fix. |
| `Spin_Retry_Count` (10) | 0 | Motor struggling to spin up — **the one most tied to a *weird noise*.** |
| `Command_Timeout` (188) | low / flat | Climbing → usually the **USB/DAS cable, enclosure or power**, not the platter (cross-check CRC). |
| `UDMA_CRC_Error_Count` (199) | 0 | Data-path (cable/bridge) errors — reseat/replace the cable, not the disk. |
| `Load_Cycle_Count` (193) | low, slow | High + fast-climbing = aggressive head-parking (rhythmic clicking); wears the drive, fixable with an idle timer. |

**Noise triage:** `Spin_Retry_Count = 0` + low `Load_Cycle_Count` + zero bad-sector counts ⇒ the sound is
almost certainly normal seek/chatter (Seagate Barracuda `ST4000DM004` are **SMR** drives and seek
audibly, especially under write load). A real "click of death" shows up as spin-retries, reallocations,
or pending sectors climbing.

## 2. Test a drive

```bash
smartctl -t short -d sat /dev/sdX     # ~2 min, safe live — quick electrical/mechanical check
smartctl -t long  -d sat /dev/sdX     # hours — reads the ENTIRE surface, finds bad sectors
smartctl -l selftest -d sat /dev/sdX  # read results (run after the test finishes)
```

"Completed without error" on a **long** test is the strongest all-clear — it's read every sector.
A test that stops at a percentage with a read failure = that LBA is bad; plan replacement.

## 3. Decide: watch or replace

- **Replace now:** `Current_Pending_Sector` or `Offline_Uncorrectable` > 0, `Reallocated` climbing,
  a long test that fails, or `-H` reports FAILED on a readable disk.
- **Watch (log the number, re-check in a week):** a handful of `Command_Timeout` with CRC at 0 (suspect
  the enclosure/cable first), a small *stable* reallocated count.
- **Not the disk:** `UDMA_CRC` climbing (cable/bridge), `SmartUnreadable` only (flag/bridge).

Your DAS disks are **SMR** — fine as a reconstructable media store, poor for sustained writes. If Frigate
ever stutters or writes stall, suspect SMR before suspecting failure.

## 4. Replace a drive

Which procedure depends on the disk's **role** (`storage.md`). Check backups first:
`./configs/pbs/verify-backups.sh`.

### 4a. A DAS pool disk (`/mnt/pool/disk1|2` on nuc1)

The pool is **mergerfs JBOD — no parity.** A dead branch loses only *that disk's* files, not the pool.
Most of it is **reconstructable** (the Arrs re-fetch the media library); irreplaceable data is already on
PBS + offsite (R26), so you restore that, you don't mourn it. Note: the pool mounts with
`x-systemd.requires=` on both branches, so a **missing disk stops the whole pool mounting** (by design,
so it never silently unions from the host root) — you bring it back degraded first.

1. **Identify the dead disk by serial** and stop whatever writes to `/mnt/media` (the Arrs/qBittorrent LXC 210).
2. **Bring the pool back degraded:** in `/etc/fstab` on nuc1, drop the dead branch from the mergerfs line
   *and* remove its `x-systemd.requires=/mnt/pool/diskN`, then `systemctl daemon-reload && mount /mnt/media`.
   The pool serves the surviving disk's files.
3. **Swap the physical disk**, format and label the replacement:
   ```bash
   mkfs.ext4 -L diskN /dev/disk/by-id/ata-…_<new-serial>
   ```
4. **Mount it back** at `/mnt/pool/diskN` by its `by-id` (never `/dev/sdX`), and restore the branch +
   `x-systemd.requires` line in `/etc/fstab`. Recreate the base dirs on the new branch so hardlinks don't
   break (`torrents/`, `library/` — `stage-b` did this originally; same reason):
   ```bash
   mkdir -p /mnt/pool/diskN/torrents /mnt/pool/diskN/library
   systemctl daemon-reload && mount /mnt/media
   ```
5. **Refill:** trigger the Arrs to re-grab what lived on the dead disk; restore any irreplaceable paths
   from PBS. Update the disk register in `storage.md` (new model/serial/by-id).

### 4b. An internal SSD (Proxmox root + `local-lvm`)

This is the serious one — it holds the host and every container's rootfs. A failure means **rebuild the
node and restore guests from PBS**, not a hot-swap. See `docs/runbook.html` (host setup stages) to
reinstall Proxmox, then `pct restore` / VM restore each guest from the PBS datastore
(`configs/pbs/verify-restore.sh` proves the restore path works). Frigate's recordings aren't backed up by
design — only its config — so expect to lose the clip history on a nuc2 SSD loss.

### 4c. The PBS datastore disk (2TB USB HDD on nuc2 → VM 900)

If this dies you lose the **backups**, not live data. Live guests keep running. Replace the disk, pass it
through to VM 900 again (`configs/pbs/pbs-vm.sh` — whole block device, `backup=0`), recreate the datastore,
and backups rebuild on the next run. The **offsite B2 copy** (`configs/pbs/offsite-*`) is the deeper safety
net — it's why 3-2-1 exists. Rotate nothing by hand; let the schedule refill it.

## 5. Monitoring reference

- **Dashboard:** Grafana → **Disks & SMART** — FAILED count, unreadable count, per-drive health +
  readability tiles, temperature history.
- **Alerts** (`configs/monitoring/alerts.yml`): `SmartFailurePredicted` (critical, real failure),
  `SmartUnreadable` (warning, bridge/flag), `DiskTempHigh` (>60°C 15m), `SmartCollectorStale`
  (smartmon.sh stopped writing — you've gone blind, treat as urgent).
- **Collector:** `configs/monitoring/smartmon.sh`, cron every 15 min on each NUC (and the Pi). It
  auto-detects the `-d` flag via `smartctl --scan-open` and reports readable/healthy/temperature.

## This system's drives (quick map — full register in `storage.md`)

| Disk | Host | Serial | Role | Fail = |
|---|---|---|---|---|
| 512GB SSD | nuc1 | MQ13W07504681 | Proxmox root + local-lvm | Rebuild node, restore from PBS (4b) |
| ST4000DM004 (SMR) | nuc1 | ZFN5Q3VL | mergerfs `/mnt/pool/disk1` | Degrade pool, re-fetch media (4a) |
| ST4000DM004 (SMR) | nuc1 | ZW63SHWZ | mergerfs `/mnt/pool/disk2` | Degrade pool, re-fetch media (4a) |
| Internal SSD | nuc2 | TBD | Proxmox root + local-lvm (Frigate 260G) | Rebuild node; Frigate clips lost (4b) |
| TOSHIBA MQ04UBD200 | nuc2 | 56KQP05LT | PBS datastore (→ VM 900) | Backups lost, live data safe (4c) |
