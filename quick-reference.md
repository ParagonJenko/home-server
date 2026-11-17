# Quick reference — URLs & IPs

Glanceable access list for every tool. `*.home.alexjenkinson.com` resolves **only on the LAN**
(split-horizon via AdGuard) or **over Tailscale** — from outside, Tailscale in first. Addressing and
reservations live in `network.md`; the Nginx routing in `services.md`; day-2 commands in
`runbooks/operations.md`.

## Dashboards & admin (reach by IP — not proxied)

| Tool | URL |
|---|---|
| Grafana | `http://192.168.1.4:3000` |
| Prometheus | `http://192.168.1.4:9090` |
| Alertmanager | `http://192.168.1.4:9093` |
| AdGuard | `http://192.168.1.4:8081` |
| Proxmox nuc1 | `https://192.168.1.2:8006` |
| Proxmox nuc2 | `https://192.168.1.3:8006` |
| PBS | `https://192.168.1.5:8007` |

## Media & apps (HTTPS via the Nginx wildcard cert — use the front name)

| Tool | URL | Direct backend |
|---|---|---|
| Plex | `https://plex.home.alexjenkinson.com` | `192.168.1.22:32400` |
| Frigate | `https://frigate.home.alexjenkinson.com` | `192.168.1.24:8971` |
| Sonarr | `https://sonarr.home.alexjenkinson.com` | `192.168.1.21:8989` |
| Radarr | `https://radarr.home.alexjenkinson.com` | `192.168.1.21:7878` |
| Bazarr | `https://bazarr.home.alexjenkinson.com` | `192.168.1.21:6767` |
| Prowlarr | `https://prowlarr.home.alexjenkinson.com` | `192.168.1.21:9696` |
| qBittorrent | `https://qbittorrent.home.alexjenkinson.com` | `192.168.1.21:8080` |

## Direct (not behind Nginx yet)

| Tool | URL |
|---|---|
| Home Assistant | `http://homeassistant.home.alexjenkinson.com` (`192.168.1.25:80`) |
| AMP | `http://amp.home.alexjenkinson.com:8080` (`192.168.1.23`) |

## Infra IPs

| Range | Host / role |
|---|---|
| `.2` / `.3` | nuc1 / nuc2 (Proxmox hosts) |
| `.4` | pi (AdGuard, Prometheus, Alertmanager, Grafana) |
| `.5` | pbs (PBS VM) |
| `.6` / `.7` | switch / access point |
| `.20` | nginx (every front name resolves here) |
| `.21` | media-pipeline (Arrs + qBittorrent) |
| `.22` / `.23` / `.24` | plex / amp / frigate |
| `.25` | home assistant |
| `.30`–`.33` | cameras (living-room / kitchen / bedroom / basement) |

DHCP: dynamic pool `.40`–`.253`; reservations `.20`–`.39`; static infra `.2`–`.19`. Router DNS = the
Pi (`192.168.1.4`), secondary empty (R14).

## SSH

`asquared ssh <box>` (`pi`/`nuc1`/`nuc2`/`pbs`/`ha`), or plain `ssh root@192.168.1.4` by IP. Key lives
in 1Password (vault *Home Server*) via its SSH agent — see `runbooks/operations.md` → *SSH from a
machine without `asquared`*.
