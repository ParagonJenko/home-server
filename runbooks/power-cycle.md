# Power-cycle runbook

Safely power the homelab **off** (cable management, moving it, a planned outage) and bring it back **on** without corruption.

## Can it handle a power-off?

Yes — a **clean** shutdown is safe, and the storage is built to survive it:

- mergerfs branches mount by **LABEL** (`media-disk1` / `media-disk2`), so the DAS disks come back even if their `/dev/sdX` letters change or you move them to different USB ports.
- The pool **refuses to mount if a branch is missing** (`x-systemd.requires=`, proven at B4) — a half-reconnected DAS fails loud instead of silently running off the host SSD.
- Containers mount-depend on the pool and boot in order (`onboot`, R18).

The one thing **not yet in place**: a UPS + NUT for automatic graceful shutdown on *unexpected* power loss (Stage J / R22). Until that exists, **never pull the mains on a running box** — always shut down cleanly first. For planned cable management that is exactly what you do.

## Current build state

Built: **NUC-1** (media stack + mergerfs pool), **NUC-2** (Frigate + PBS VM + HA VM), the **Pi** (DNS + monitoring), **PBS** and the offsite sync. Still pending: the **UPS + NUT** for automatic graceful shutdown on power loss (Stage J / R22) — so until that lands, **always shut down cleanly before cutting power**. The full ordering below is now live. Update this line as remaining stages land.

## Power OFF — reverse dependency order

Shut each box down cleanly; a Proxmox host stops its guests automatically on the way down.

1. **Finish or pause anything writing** — a PBS backup, a torrent. (`pct list`, and check PBS tasks.)
2. **NUC-2** (Frigate + PBS VM + HA VM): `shutdown -h now`, or the Proxmox web UI. Waits for the guests to stop, then halts.
3. **NUC-1** (containers + mergerfs pool): `shutdown -h now`. Stops the guests, unmounts `/mnt/media` and the branches, then halts.
4. **Pi** (DNS): `sudo shutdown -h now`.
5. **Wait for every box's activity LEDs to go dark** before pulling power. The DAS and USB HDD unmount as part of the host shutdown — safe to unplug once the host is off.

## Manage cables

Everything is off and all disks are unmounted — safe to unplug, re-route and reconnect. The LABEL mounts mean the pool rebuilds by identity even if you change which USB port a DAS disk sits in.

## Power ON — dependency order (R18)

**Reconnect everything first**, then power on in order:

1. **Reconnect all cables and disks** — both DAS disks to NUC-1, the USB HDD to NUC-2. A missing DAS disk makes NUC-1's pool refuse to mount (by design).
2. **Pi first** — it is the DNS everything resolves through. Wait until it answers: from another box, `getent hosts pi.home.alexjenkinson.com` (or `getent hosts plex.home.alexjenkinson.com`).
3. **NUC-1** — mounts the branches by LABEL, then the mergerfs pool (requires both branches), then starts containers in `onboot` order.
4. **NUC-2** — Frigate, the PBS VM and HA start.

## Verify after power-on

- Pool back: `df -h /mnt/media` shows ~7T; `findmnt /mnt/media` shows `fuse.mergerfs`.
- Branches mounted: `lsblk -f` shows `media-disk1` / `media-disk2` at `/mnt/pool/disk{1,2}`.
- Guests up: `pct list` and `qm list` show them running.
- DNS: `getent hosts plex.home.alexjenkinson.com` resolves.
- Full pool re-check (optional): `./configs/verify.sh B2`.

## If a disk didn't come back

The pool refusing to mount is the safety net working, **not** a fault.

- `lsblk` / `blkid -L media-disk1` — is the disk present and labelled?
- Reconnect it, then on NUC-1: `mount -a`.
- `systemctl status mnt-media.mount` for the reason if it still won't mount.

## Boot hangs: "Timed out waiting for device … Media-disk"

**Symptom:** a host won't come back after a power-cycle — unreachable over the network and the Proxmox web UI — and its **console** shows `Timed out waiting for device …` naming the media disk (a systemd device unit like `dev-disk-by\x2dlabel-media\x2ddisk1.device`), or `A start job is running for … /mnt/media`. It sits on that for ~90s, then may drop to an emergency shell. Pinging the host from elsewhere gives *"Destination host unreachable"* (your own machine, not the host, answering).

**Cause:** the **DAS/NAS (the media disk) was powered off or unplugged** when the host booted. The branch mounts depend on the disk's device unit (`x-systemd.requires=`); with the disk absent that unit never appears, so the mount — and the boot — wait on it and time out. This is the same safety net that stops the pool unioning off the host SSD, just hit at boot time rather than at `mount`.

**Fix:**
1. Power the DAS/NAS back on; check its data (USB) cable is seated.
2. Wait for the disks to spin up and enumerate (`lsblk` on another box won't help — go to the affected host).
3. **Reboot the host** — it now finds the device, mounts the branches by LABEL, mounts the pool, and continues.
4. If it's sitting at an **emergency shell** instead: confirm the disk is present (`blkid -L media-disk1`), then `mount -a` and `systemctl default`. A clean reboot is simpler.

**Prevent:** follow the power-ON order (R18) — reconnect and power the disks **before** the hosts. DAS on before NUC-1; USB HDD on before NUC-2.

**Optional hardening (R9 — the host should boot even with a data disk missing):** if you'd rather the host always come up reachable (so you can fix a missing disk remotely instead of needing a monitor), add `nofail,x-systemd.device-timeout=30s` to the branch mounts in the fstab snippet. The host then boots in ~30s without the pool (the mergerfs mount and the media containers stay down until the disk returns) instead of hanging. Trade-off: a genuinely missing disk fails quietly at boot rather than loudly refusing. Not applied yet — decide and apply deliberately.

## Never

- Pull the mains on a running box (until the UPS + NUT is in place — and even then, let NUT trigger the shutdown).
- Boot NUC-1 with a DAS disk unplugged and then force the pool up — that unions from the host SSD. Reconnect the disk instead.
