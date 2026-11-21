# network.md

Owns every MAC and IP, and the DNS rewrite groups. Update in the same change as the device going in. MACs and IPs belong here; **credentials never do**.

## Addressing plan

Router `192.168.1.1`, /24, DHCP **dynamic pool `.40`–`.253`**. The reserved blocks sit *outside* the dynamic pool on purpose — `.2`–`.19` for static infra and `.20`–`.39` for container/camera reservations — so the router can never hand a dynamic lease to an address something is reserved at. (If the pool starts at `.20`, dynamic clients land on the reservation band and reservations fight the pool — set Pool Start to `.40`.) Router's handed-out **DNS = the Pi (`192.168.1.4`), secondary empty** (R14).

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
| nuc1 — Beelink S13, Proxmox host | static | `192.168.1.2` | TBD | nuc1.home.alexjenkinson.com | Dual NIC — record the MAC of the port actually patched |
| nuc2 — Beelink S12 Pro, Proxmox host | static | `192.168.1.3` | TBD | nuc2.home.alexjenkinson.com | |
| pi — AdGuard/Prometheus/Alertmanager/Grafana | static | `192.168.1.4` | TBD | pi.home.alexjenkinson.com | The resolver itself; the one literal IP configs may contain (R13). OS hostname is `raspberry-pi-5` (cosmetic — reached by IP + `pi.home.alexjenkinson.com`, not hostname) |
| pbs — VM 900 | static | `192.168.1.5` | TBD | pbs.home.alexjenkinson.com | `pvesm add pbs --server pbs.home.alexjenkinson.com` uses the name, never this IP |
| switch — managed | static | `192.168.1.6` | TBD | — | Management address only |
| ap — access point(s) | static | `192.168.1.7` | TBD | — | DHCP-issued DNS must also be the Pi (R14) |
| nginx — LXC 240 | reserved | `192.168.1.20` | BC:24:11:18:CB:C0 | — | **Every front name resolves to this IP.** Fill first |
| media-pipeline — LXC 210 | reserved | `192.168.1.21` | BC:24:11:D8:99:DD | media-pipeline.home.alexjenkinson.com (sonarr/radarr/bazarr/prowlarr/qbittorrent.home.alexjenkinson.com) | Never proxied under its own name; it is Nginx's backend target |
| plex — LXC 220 | reserved | `192.168.1.22` | BC:24:11:2B:4B:45 | plex-lxc.home.alexjenkinson.com (front: plex.home.alexjenkinson.com) | Backend name points here; front points at Nginx |
| amp — LXC 230 | reserved | `192.168.1.23` | BC:24:11:07:4E:37 | amp-lxc.home.alexjenkinson.com (front: amp.home.alexjenkinson.com) | Proxied by Nginx (:443 → backend :8080). Backend name points here; front points at Nginx |
| frigate — LXC 111 (nuc2, privileged) | reserved | `192.168.1.24` | BC:24:11:93:A9:FA | frigate-lxc.home.alexjenkinson.com (front: frigate.home.alexjenkinson.com) | Port 5000 is unauthenticated — never proxy/expose |
| homeassistant — VM 910 (nuc2) | reserved | `192.168.1.25` | bc:24:11:27:42:ce | homeassistant.home.alexjenkinson.com | Accessed directly on :80 (restored config; HAOS default is 8123). Proxying needs `use_x_forwarded_for` + `trusted_proxies` in HA's config |
| cam-living-room | reserved | `192.168.1.30` | 10:2C:B1:DB:1A:F6 | cam-living-room.home.alexjenkinson.com | Frigate opens RTSP by name — a lost reservation breaks recording. **Different vendor OUI (10:2C:B1) from the Eufy cams — confirm its RTSP path isn't `/live0`** |
| cam-kitchen | reserved | `192.168.1.31` | 04:17:B6:6E:CD:14 | cam-kitchen.home.alexjenkinson.com | Eufy/Anker (04:17:B6) |
| cam-bedroom | reserved | `192.168.1.32` | 04:17:B6:4A:9C:FE | cam-bedroom.home.alexjenkinson.com | Eufy/Anker |
| cam-basement | reserved | `192.168.1.33` | 04:17:B6:44:C1:33 | cam-basement.home.alexjenkinson.com | Eufy/Anker |

## DNS rewrite groups (AdGuard)

Three groups — nothing resolves without all three. `configs/pi/adguard-rewrites.py` reads this table and pushes them over the API.

1. **Front names → Nginx's IP** (`.20`): `plex.home.alexjenkinson.com`, `frigate.home.alexjenkinson.com`, `sonarr.home.alexjenkinson.com`, `radarr.home.alexjenkinson.com`, `bazarr.home.alexjenkinson.com`, `prowlarr.home.alexjenkinson.com`, `qbittorrent.home.alexjenkinson.com`, `amp.home.alexjenkinson.com`, `start.home.alexjenkinson.com` (static start page served by Nginx, not a proxy).
2. **Backend names → the container's own IP**: `plex-lxc.home.alexjenkinson.com`, `frigate-lxc.home.alexjenkinson.com`, `media-pipeline.home.alexjenkinson.com`, `amp-lxc.home.alexjenkinson.com`.
3. **Hosts & cameras → their own IP**: `cam-*.home.alexjenkinson.com`, `homeassistant.home.alexjenkinson.com`, `nuc1`, `nuc2`, `pbs`, `pi.home.alexjenkinson.com`.

## Resolver policy

- Router DNS = the Pi, and **only** the Pi. Leave the secondary field empty (a public secondary silently breaks `*.home.alexjenkinson.com` intermittently).
- Each NUC and the PBS VM point their own resolver at the Pi (set at H3) — or `pbs.home.alexjenkinson.com` stops resolving from the hosts.
- AdGuard's *upstream* is where `1.1.1.1` belongs.
