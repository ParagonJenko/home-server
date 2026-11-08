# rules.md

The guardrails the build is held to. Each rule is **statement**, **why it exists**, and **how it's verified**. A rule is only "done" when its verify step has actually been performed and recorded.

Status markers: **ON HOLD** (deferred), **PARTIAL** (physically possible now, full form deferred).

## Storage & data safety

### R1 — Storage expands by adding a disk, never by rebuilding
- **Why:** ad-hoc capacity growth — bolting extra mounts onto a shared pool — is how the original corruption-prone layout accreted.
- **Verify:** adding capacity = attach disk + append one branch to the mergerfs config. No data moves, no service reconfigures, Plex's library path is unchanged.

### R5 — A workload filling is graceful; the system filling is impossible
- **Why:** all three past failures came from a shared pool hitting 100% and aborting the ext4 journals inside container images.
- **Verify:** the fill test (R10) passes on every data filesystem, and R6–R11 all hold.

### R6 — Every workload has an enforced hard ceiling below the disk's real capacity
- **Why:** without a per-workload ceiling, one service consumes the whole device.
- **Verify:** container disks, downloads, Frigate retention and PBS retention each have a numeric limit, and the sum of ceilings on any shared device is under device size minus reserved headroom (checked at B8).

### R7 — Each workload's behaviour at "full" is a chosen, configured degradation
- **Why:** the default — writes fail, then the filesystem aborts — is the catastrophic path.
- **Verify:** Frigate prunes oldest; Arrs and qBittorrent pause and alert; Plex stops importing but keeps serving. No service's answer is "write until the disk errors."

### R8 — Every filesystem keeps reserved headroom no workload can allocate
- **Why:** corruption happens at metadata exhaustion near 100%; a floor of free space prevents ever reaching it.
- **Verify:** ext4 reserved-blocks ≥5% on root and container storage; mergerfs `minfreespace` on the media pool; the LVM-thin metadata volume has autoextend on and is monitored. Read the live settings, don't assume.

### R9 — The host OS survives any workload or disk filling up
- **Why:** a full data disk or container must never make a host unbootable — the original failure.
- **Verify:** workloads run on capped LVM-thin volumes, never on the host root filesystem; the sum of LV caps on each SSD is under its size minus headroom (B8); anything that can grow without a hard cap (media, recordings, backups) lives off the host SSD on the DAS or USB HDD. A full LV goes read-only without taking the host down (B8).

### R10 — Storage limits are proven by a deliberate fill test before sign-off
- **Why:** the old setup's behaviour at 100% was discovered in production, not verified.
- **Verify:** a throwaway volume was filled to its limit on every data filesystem (mergerfs pool and local-lvm); the observed result was a graceful stop with zero corruption, recorded in `storage.md`.

### R26 — Data is classed by whether it can be re-downloaded
- **Why:** media is reconstructable; configs, photos and documents are not, and treating them alike either wastes offsite space or under-protects the irreplaceable.
- **Verify:** irreplaceable data is tagged and gets full offsite 3-2-1; reconstructable media is backed up to a lighter standard by deliberate, recorded choice in `storage.md`.

## Recovery, backups & documentation

### R2 — One always-current source of truth documents the whole system
- **Why:** diagnosing blind wastes hours.
- **Verify:** this off-box repo holds current inventory, service map, storage map with every limit, network/DNS/DHCP and runbooks — updated in the same change as whatever it describes.

### R3 — Backups are reachable within minutes, without first fixing what broke
- **Why:** a backup you can't get to during the outage isn't a backup.
- **Verify:** the PBS web UI lists all restore points; the PBS VM config is backed up off-NUC-2 so PBS can be rebuilt; an offsite copy is the second access path.

### R4 — Any service restores to a point in time; the whole site survives a disaster
- **Why:** routine "I broke X" needs rollback; fire, theft or a surge needs offsite survival.
- **Verify:** PBS holds scheduled retained backups of every guest; the datastore syncs offsite (E7) and the docs repo is offsite. Both proven by R12.

### R12 — Recovery is rehearsed, and the runbook is proven
- **Why:** an untested restore is a hypothesis.
- **Verify:** a real restore from PBS has succeeded (local minimum), and — the full bar — a restore from the offsite copy and onto different hardware, following the written runbook.

### R17 — The system rebuilds from the docs repo + backups on any hardware
- **Why:** a box may die mid-move; rebuild must not need tribal knowledge.
- **Verify:** this repo (off-box) plus PBS (with offsite copy) plus the secrets vault (R21) together contain everything. No required step exists only in someone's memory.

### R21 — Every secret survives a bare-metal rebuild
- **Why:** R17's "rebuild from docs + PBS" is false if a secret exists only as a gitignored file on a box that just died.
- **Verify:** each secret — Grafana admin, AdGuard admin, Discord webhook, Eufy RTSP, AMP/Plex, Recyclarr, Arr/Prowlarr API keys, root/PBS logins, PBS datastore encryption key, PBS fingerprint, Proxmox API token, every SSH key, Tailscale auth, offsite crypt key — has an off-box copy in a password manager or encrypted vault, and a rebuild restores them from there, not from a surviving box. Rotate anything that ever touched git history.

### R25 — Software stays patched, and a bad update rolls back
- **Why:** a clean install has no story for month six; unpatched services are the slow attack surface, and an update with no rollback is a gamble.
- **Verify:** unattended security updates are on across hosts and containers; every manual upgrade is preceded by a PBS restore point; the rollback is the proven R12 path.

## Networking, portability & power

### R13 — No internal service depends on a fixed IP address
- **Why:** hardcoded IPs broke everything when the network changed.
- **Verify:** grep all service configs for literal IPs — only the uplink/gateway and the DNS server itself may appear in `configs/`. Static infra IPs (NUC/PBS) are device/install config, not service config. Interim: pin addresses with DHCP reservations on the router.

### R14 — The homelab carries its own authoritative internal DNS
- **Why:** naming must travel with the kit, not depend on the venue's router.
- **Verify:** the Pi resolves internal names; every service and AP uses it as primary DNS; internal resolution works with the WAN unplugged.

### R15 — The homelab serves its own DHCP; the venue router is uplink only — **ON HOLD**
- **Why:** owning addressing means an identical internal network on any site.
- **Verify:** deferred until a dedicated router (Ubiquiti planned) can replace the ISP router's DHCP. Do not enable Pi DHCP while the ISP router still serves it. Interim: DHCP reservations on the ISP router.

### R16 — Exactly one uplink point connects the stack to any external network — **PARTIAL until R15**
- **Why:** relocation means moving the island and plugging one cable into any internet source.
- **Verify:** all servers, cameras, APs and clients sit on the internal switch; a single WAN link touches the venue network. Physical topology can be built now; addressing portability waits on R15.

### R18 — After power loss, everything returns in the correct order, unattended
- **Why:** relocation means power-cycling; nothing may need manual start-in-sequence.
- **Verify:** boot order is DNS → storage mounts → dependent services, via onboot ordering, startup delays and mount dependencies. The Pi (separate box, sole DNS) powers up first. A cold power-cycle brings the full stack up with no human action.

### R20 — Remote access follows the kit, independent of the venue's network
- **Why:** Plex-outside-home and custom apps currently rely on the home IP and port forwards, which break on relocation.
- **Verify:** Tailscale provides remote access by stable name regardless of the underlying network; no port forwarding on the venue router is required.

### R22 — Power loss pauses the system; it never corrupts it
- **Why:** R18 brings the stack back in order, but a mid-write power cut aborts an ext4 journal the same way a full disk does.
- **Verify:** a UPS powers both NUCs, the DAS, the Pi and the USB HDD; NUT runs an ordered graceful shutdown (every box, Pi included) before the battery dies; pulling mains leaves zero corruption and the stack returns unattended via R18.

### R23 — Nothing is reachable from the internet except through the private overlay
- **Why:** a port forward on the venue router is standing attack surface that moves with the kit and outlives the reason it was added.
- **Verify:** no inbound port forward or UPnP rule exists anywhere; Tailscale is the only ingress; a scan of the WAN IP shows no open ports. Re-run on every relocation.

### R24 — Failing hardware warns before it fails
- **Why:** a dead DAS disk turns R1's "add a disk" into "restore from backup".
- **Verify:** SMART health and temperature are scraped for every disk (USB/DAS disks need `-d sat`); a predicted failure or over-temp fires a critical alert; a scheduled SMART self-test runs and is recorded in `storage.md`.

### R27 — Cameras and IoT are isolated from trusted devices — **ON HOLD until R15**
- **Why:** the Eufy cameras phone home and are the least-trusted things on the network; a flat network lets them reach everything.
- **Verify:** once the dedicated router (R15) lands, cameras and IoT sit on their own VLAN that can reach the internet and Frigate but not trusted clients.

## Config discipline

### R11 — Alerts inform; they never protect
- **Why:** any safety that depends on a human seeing an alert will eventually fail when the alert is missed.
- **Verify:** every "must not happen" is guaranteed by a hard mechanism (R6/R8/R9). Disabling all alerting would not enable any corruption path. Alerts fire at 80% as a heads-up only.

### R19 — Configuration is defined as files, not manual clicks
- **Why:** "take it anywhere" must mean "re-apply definitions", not "remember what I clicked".
- **Verify:** each service is defined by a compose file, container definition or documented build in this repo; an agent can recreate any service from its definition alone.
