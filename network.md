# network.md

Owns every MAC and IP, and the DNS rewrite groups. Update in the same change as the device going in. MACs and IPs belong here; **credentials never do**.

## Addressing plan

Router `192.168.1.1`, /24, DHCP pool `.20`–`.253`. That leaves `.2`–`.19` outside the pool for the static block.

| Band | Use |
|---|---|
| `.1` | Gateway (ISP router) |
| `.2`–`.19` | Static infra (set on the device, not reserved) |
| `.20`–`.39` | Containers & cameras (DHCP reservations) |
| `.40`+ | Dynamic (phones, TVs) |

Two mechanisms, on purpose: every LXC is created `ip=dhcp`, so a reservation pins it and it stays portable — while Proxmox, PBS and the Pi write their address into config at install (or, for the Pi, *are* the resolver, which must not depend on a lease from a router you don't own).

## Address register

MACs are generated at `pct create`, so collect them off the real device after Stage E. `TBD` = not yet collected.

| Device | Kind | Reserved IP | MAC | Names | Notes |
|---|---|---|---|---|---|
| nuc1 — Beelink S13, Proxmox host | static | `192.168.1.2` | TBD | nuc1.home | Dual NIC — record the MAC of the port actually patched |
| nuc2 — Beelink S12 Pro, Proxmox host | static | `192.168.1.3` | TBD | nuc2.home | |
| pi — AdGuard/Prometheus/Alertmanager/Grafana | static | `192.168.1.4` | TBD | pi.home | The resolver itself; the one literal IP configs may contain (R13) |
| pbs — VM 900 | static | `192.168.1.5` | TBD | pbs.home | `pvesm add pbs --server pbs.home` uses the name, never this IP |
| switch — managed | static | `192.168.1.6` | TBD | — | Management address only |
| ap — access point(s) | static | `192.168.1.7` | TBD | — | DHCP-issued DNS must also be the Pi (R14) |
| nginx — LXC 240 | reserved | `192.168.1.20` | TBD | — | **Every front name resolves to this IP.** Fill first |
| media-pipeline — LXC 210 | reserved | `192.168.1.21` | TBD | media-pipeline.home (sonarr/radarr/bazarr/prowlarr.home) | Never proxied under its own name; it is Nginx's backend target |
| plex — LXC 220 | reserved | `192.168.1.22` | TBD | plex-lxc.home (front: plex.home) | Backend name points here; front points at Nginx |
| amp — LXC 230 | reserved | `192.168.1.23` | TBD | amp.home (add when installed) | |
| frigate — LXC 111 (nuc2, privileged) | reserved | `192.168.1.24` | TBD | frigate-lxc.home (front: frigate.home) | Port 5000 is unauthenticated — never proxy/expose |
| cam-living-room | reserved | `192.168.1.30` | TBD | cam-living-room.home | Frigate opens RTSP by name — a lost reservation breaks recording |
| cam-kitchen | reserved | `192.168.1.31` | TBD | cam-kitchen.home | |
| cam-bedroom | reserved | `192.168.1.32` | TBD | cam-bedroom.home | |
| cam-basement | reserved | `192.168.1.33` | TBD | cam-basement.home | |

## DNS rewrite groups (AdGuard)

Three groups — nothing resolves without all three. `configs/pi/adguard-rewrites.py` reads this table and pushes them over the API.

1. **Front names → Nginx's IP** (`.20`): `plex.home`, `frigate.home`, `sonarr.home`, `radarr.home`, `bazarr.home`, `prowlarr.home`.
2. **Backend names → the container's own IP**: `plex-lxc.home`, `frigate-lxc.home`, `media-pipeline.home`.
3. **Hosts & cameras → their own IP**: `cam-*.home`, `nuc1`, `nuc2`, `pbs`, `pi.home`.

## Resolver policy

- Router DNS = the Pi, and **only** the Pi. Leave the secondary field empty (a public secondary silently breaks `*.home` intermittently).
- Each NUC and the PBS VM point their own resolver at the Pi (set at H3) — or `pbs.home` stops resolving from the hosts.
- AdGuard's *upstream* is where `1.1.1.1` belongs.
