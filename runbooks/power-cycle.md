# Power-cycle runbook

Safely power the homelab **off** (cable management, moving it, a planned outage) and bring it back **on** without corruption.

## Can it handle a power-off?

Yes — a **clean** shutdown is safe, and the storage is built to survive it:

- mergerfs branches mount by **LABEL** (`media-disk1` / `media-disk2`), so the DAS disks come back even if their `/dev/sdX` letters change or you move them to different USB ports.
- The pool **refuses to mount if a branch is missing** (`x-systemd.requires=`, proven at B4) — a half-reconnected DAS fails loud instead of silently running off the host SSD.
- Containers mount-depend on the pool and boot in order (`onboot`, R18).

The one thing **not yet in place**: a UPS + NUT for automatic graceful shutdown on *unexpected* power loss (Stage J / R22). Until that exists, **never pull the mains on a running box** — always shut down cleanly first. For planned cable management that is exactly what you do.

## Current build state

Only **NUC-1** exists so far (Stages A–B). No Pi, NUC-2, PBS or UPS yet. So right now the whole thing is just:

1. Clean-shutdown NUC-1 — `shutdown -h now`
2. Reconnect **both** DAS disks
3. Power on

The full ordering below matters once the Pi and NUC-2 are built. Update this file's build-state line as stages land.

## Power OFF — reverse dependency order

Shut each box down cleanly; a Proxmox host stops its guests automatically on the way down.

1. **Finish or pause anything writing** — a PBS backup, a torrent. (`pct list`, and check PBS tasks.)
2. **NUC-2** (Frigate + PBS VM): `shutdown -h now`, or the Proxmox web UI. Waits for the guests to stop, then halts.
3. **NUC-1** (containers + mergerfs pool): `shutdown -h now`. Stops the guests, unmounts `/mnt/media` and the branches, then halts.
4. **Pi** (DNS): `sudo shutdown -h now`.
5. **Wait for every box's activity LEDs to go dark** before pulling power. The DAS and USB HDD unmount as part of the host shutdown — safe to unplug once the host is off.

## Manage cables

Everything is off and all disks are unmounted — safe to unplug, re-route and reconnect. The LABEL mounts mean the pool rebuilds by identity even if you change which USB port a DAS disk sits in.

## Power ON — dependency order (R18)

**Reconnect everything first**, then power on in order:

1. **Reconnect all cables and disks** — both DAS disks to NUC-1, the USB HDD to NUC-2. A missing DAS disk makes NUC-1's pool refuse to mount (by design).
2. **Pi first** — it is the DNS everything resolves through. Wait until it answers: from another box, `getent hosts pi.home` (or `getent hosts plex.home`).
3. **NUC-1** — mounts the branches by LABEL, then the mergerfs pool (requires both branches), then starts containers in `onboot` order.
4. **NUC-2** — Frigate and the PBS VM start.

## Verify after power-on

- Pool back: `df -h /mnt/media` shows ~7T; `findmnt /mnt/media` shows `fuse.mergerfs`.
- Branches mounted: `lsblk -f` shows `media-disk1` / `media-disk2` at `/mnt/pool/disk{1,2}`.
- Guests up: `pct list` and `qm list` show them running.
- DNS: `getent hosts plex.home` resolves.
- Full pool re-check (optional): `./configs/verify.sh B2`.

## If a disk didn't come back

The pool refusing to mount is the safety net working, **not** a fault.

- `lsblk` / `blkid -L media-disk1` — is the disk present and labelled?
- Reconnect it, then on NUC-1: `mount -a`.
- `systemctl status mnt-media.mount` for the reason if it still won't mount.

## Never

- Pull the mains on a running box (until the UPS + NUT is in place — and even then, let NUT trigger the shutdown).
- Boot NUC-1 with a DAS disk unplugged and then force the pool up — that unions from the host SSD. Reconnect the disk instead.
