# Operations runbook (day-2)

Running the homelab after it's built: getting onto each box, routine maintenance, adding
guests, DNS/DHCP changes, backups and health checks. For every tool's URL/IP at a glance see
[`quick-reference.md`](../quick-reference.md); for power-off/on and boot problems see
`power-cycle.md`; for the full build see `docs/runbook.html`.

## The `asquared` CLI

`bin/asquared` wraps the common jobs. Install it once per box (it's in the repo each box already has):

```bash
ln -s ~/home-server/bin/asquared /usr/local/bin/asquared
ln -s ~/home-server/bin/asquared /usr/local/bin/asq      # optional short alias
asquared help
```

`asq` and `asquared` are the same command — use whichever you like.

| Command | What it does | Where |
|---|---|---|
| `asquared status` | what's running here + ping every other box | any |
| `asquared ssh <box> [cmd]` | ssh to `pi`/`nuc1`/`nuc2`/`pbs`/`ha` (by static IP) | any |
| `asquared enter <id>` | `pct enter` a container | PVE host |
| `asquared start\|stop\|restart <id>` | control a guest (confirms stop/restart) | PVE host |
| `asquared logs <id\|service>` | container/VM log, or a Pi docker service's logs | PVE / Pi |
| `asquared update` | apt upgrade (+ docker pull & recreate on the Pi), with confirm | any |
| `asquared backup <id>` | `vzdump` a guest to PBS right now | PVE host |
| `asquared dns` | re-apply AdGuard rewrites from `network.md` | Pi |
| `asquared verify <STEP>` | run `./configs/verify.sh <STEP>` | any |

It uses the **static infra IPs** (nuc1 `.2`, nuc2 `.3`, pi `.4`, pbs `.5`, ha `.25`) so it works
even when DNS is down — which is exactly when you need it.

## Getting onto each box

- **Proxmox hosts (nuc1/nuc2):** `asquared ssh nuc1`, or the web UI at `https://192.168.1.2:8006` / `.3:8006`.
- **Pi:** `asquared ssh pi`. Grafana `:3000`, Prometheus `:9090`, AdGuard `:8081`.
- **PBS:** `asquared ssh pbs`, or the web UI at `https://192.168.1.5:8007`.
- **A container:** on its host, `asquared enter <id>` (`pct enter`). For a container that runs Docker (Plex, Frigate, AMP): `pct exec <id> -- docker exec -it <name> sh`.
- **Home Assistant:** `asquared ssh ha` (HAOS SSH on port 22222), or the HA UI, or manage config from nuc2 with `./configs/homeassistant/ha-config.sh`.
- **A VM's screen:** Proxmox web UI → the VM → Console (the only way into HAOS/PBS before SSH).

## SSH from a machine without `asquared`

`asquared ssh <box>` is the shortcut; under it, every box takes a plain SSH by IP as **root**:

```
ssh root@192.168.1.4     # pi    (also .2 nuc1, .3 nuc2, .5 pbs)
ssh root@192.168.1.25 -p 22222   # ha  (HAOS SSH add-on)
```

**The key lives in 1Password** (vault *Home Server*), served by the 1Password SSH agent — nothing
is written into `~/.ssh`. To use it on a new machine:

1. **Enable the agent** in 1Password → Settings → Developer → *Use the SSH agent*, and list the vault
   in `agent.toml` so it offers that key:
   ```
   [[ssh-keys]]
   vault = "Home Server"
   ```
   (Windows config: `~\.config\1Password\ssh\agent.toml`; macOS/Linux: `~/.config/1password/ssh/agent.toml`.)
   Restart 1Password, then `ssh-add -l` should list the Home Server key.
2. **Authorise the key on the box** (first time only). From a machine already in, or via the Proxmox/PBS
   console, append the public key (1Password → the SSH item → *public key*) to `/root/.ssh/authorized_keys`:
   ```
   install -d -m700 /root/.ssh
   echo 'ssh-ed25519 AAAA... home-server' >> /root/.ssh/authorized_keys
   chmod 600 /root/.ssh/authorized_keys
   ```

### Gotchas (what actually bit me)
- **Connected but "Permission denied" / no route:** a VPN (Mullvad, etc.) is swallowing LAN traffic.
  Turn on the client's **"Local network sharing"** so `192.168.1.0/24` is reachable.
- **`Permission denied (publickey)`:** the agent isn't offering the Home Server key — it's serving a
  *different* vault's key. Fix `agent.toml` (step 1) and restart 1Password; confirm with `ssh-add -l`.
- **Bootstrapping a new machine with no key yet:** password login as root is blocked by default
  (`PermitRootLogin prohibit-password`). Get in from a machine that already works, or the VM console,
  and authorise the new key as in step 2 — don't try to re-enable root password SSH.

## Routine maintenance

- **Health at a glance:** `asquared status` on each box. Grafana's *Homelab overview* dashboard; alerts arrive in Discord.
- **Updates:** `asquared update` per box. On a Proxmox host, `reboot` if the kernel changed. Do one box at a time and check it's back before the next.
- **Backups are running:** `./configs/pbs/verify-backups.sh` on each NUC, and the PBS UI → the datastore → Content. A manual one: `asquared backup <id>`.
- **Storage headroom:** `asquared status` shows the thin-pool data/metadata %. The *ThinPoolMetadataHigh* alert (80%) is the one closest to unrecoverable — act on it.
- **Adding or re-provisioning a camera:** see [`cameras.md`](cameras.md) — RTSP → DHCP reservation (.30–.33) → AdGuard rewrite → Frigate `.env`. `configs/frigate/find-cameras.sh` discovers MACs.

## Add a new container (LXC)

Don't hand-roll it — copy the nearest existing stage script as a template; they already wire up
the idmap, mounts and Tailscale-tun shims for unprivileged containers.

1. **Reserve its identity first** (R13): pick an ID, add a row to `network.md` in the reservation band (`.20`–`.39`) with a MAC, and add the AdGuard rewrite (`asquared dns` on the Pi after editing). Add the DHCP reservation in the router (MAC → IP).
2. **Copy a template:** `configs/lxc/amp.sh` (native app) or `configs/lxc/plex.sh` (Docker + media mount + Tailscale) is the closest starting point. Change the CTID, hostname, resources.
3. **Keep the helpers it needs:** `apply_idmap` (unprivileged), `apply_requires_mount` (if it uses the media pool, R9), `apply_tailscale_tun` (if it runs Tailscale directly).
4. **Deploy + verify:** run the script on the host, then write a `verify-<svc>.sh` and add the guest to the PBS backup job (Datacenter → Backup).

## Add a new VM

Same shape with `qm`: `configs/homeassistant/haos-vm.sh` (imports a prebuilt qcow2) and
`configs/pbs/pbs-vm.sh` (ISO install + disk passthrough) are the templates. Reserve its IP/MAC in
`network.md`, give it `--onboot 1`, and add it to a backup job.

## DNS — add or change a name

1. Edit `network.md` (the one canonical address register) — add/adjust the name → IP row and its group.
2. On the Pi: `asquared dns` (runs `configs/pi/adguard-rewrites.py --apply`).
3. Confirm: `./configs/pi/adguard-rewrites.py --check` — it fails if a documented name isn't pushed.

Front names (proxied services) point at Nginx `.20`; backend/own-IP names point at the container.
A proxied service needs **both** (e.g. `plex.home…` → Nginx, `plex-lxc.home…` → the container).

## DHCP reservation

Add it in the **router's admin UI** (MAC → IP, from `network.md`) — it's a router setting, not a
command, until L2 (AdGuard DHCP) lands. Never assign a fixed IP on the device itself for a guest
(R13); infra boxes (NUCs/Pi/PBS, `.2`–`.5`) are the exception and set theirs at install.

## Backups & restore on demand

- **Back up now:** `asquared backup <id>`.
- **Prove a restore:** `./configs/pbs/verify-restore.sh <id>` — restores to a throwaway CT, boots it, tears it down.
- **Real restore:** `pct restore <newid> <volid> --storage local-lvm` (get `<volid>` from `pvesm list pbs-backup`). For the offsite copy, restore from the B2 remote on the PBS VM.

## Health checks

`asquared verify <STEP>` runs the matching check in `configs/verify.sh`. Useful ones:
`B2` (media pool), `H1` (monitoring up), `H2` (node_exporter + thinpool), `H4` (alert → Discord),
`G4`/`G5` (PBS + backup coverage), `I2` (guardrails). No automated check for a step → it's a
by-hand verify in the build runbook.

## When something's down

1. `asquared status` — what's up, what's not, and is the box reachable.
2. `asquared logs <id>` (or `docker compose logs` on the Pi) — the reason is almost always in there.
3. The service's config lives in `configs/<service>/` — it rebuilds from there, so fix the file and redeploy, don't hand-edit the running copy.
4. **Won't boot after a power event / "Timed out waiting for device":** `power-cycle.md`.
5. **Internal names don't resolve:** is the Pi up (`asquared ssh pi`)? Is AdGuard running? Is this box's resolver the Pi (`cat /etc/resolv.conf` → `192.168.1.4`)?
