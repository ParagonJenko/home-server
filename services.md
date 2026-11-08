# services.md

The service map and the Nginx routing table. Every proxied service has two DNS names: a **front** name that resolves to Nginx, and a **backend** name that resolves to the container itself (so Nginx doesn't loop back to itself).

## Service map

| Service | Host | Guest | Port(s) | Proxied? |
|---|---|---|---|---|
| Nginx (reverse proxy) | nuc1 | LXC 240 | 80 | — (is the proxy) |
| qBittorrent | nuc1 | LXC 210 | 8080 | via front name |
| Sonarr / Radarr / Bazarr / Prowlarr | nuc1 | LXC 210 | 8989 / 7878 / 6767 / 9696 | via front names |
| FlareSolverr | nuc1 | LXC 210 | 8191 | internal only |
| Plex | nuc1 | LXC 220 | 32400 | via front name |
| AMP | nuc1 | LXC 230 | TBD | — |
| Frigate | nuc2 | LXC 111 | 8971 (auth UI), 5000 (**unauth — never expose**) | via front name |
| PBS | nuc2 | VM 900 | 8007 | — |
| AdGuard | pi | — | 53 (DNS), 8081 (admin) | — |
| Grafana | pi | — | 3000 | — |
| Prometheus | pi | — | 9090 | — |
| Alertmanager | pi | — | 9093 | — |
| blackbox_exporter | pi | — | 9115 | — |
| node_exporter | pi + both NUCs | — | 9100 | — |

## Routing table (Nginx, `configs/nginx/homelab.conf`)

Routes by `Host:` header. Backends are addressed by name, through the Pi resolver, with the variable `proxy_pass` form so Nginx honours DNS TTL.

| Front name | → Nginx routes to |
|---|---|
| `plex.home` | `plex-lxc.home:32400` |
| `frigate.home` | `frigate-lxc.home:8971` |
| `sonarr.home` | `media-pipeline.home:8989` |
| `radarr.home` | `media-pipeline.home:7878` |
| `bazarr.home` | `media-pipeline.home:6767` |
| `prowlarr.home` | `media-pipeline.home:9696` |

## Notes

- The proxy is **HTTP-only on port 80** — `.home` is not a public TLD, so no CA can issue a cert. LAN logins travel in the clear; Tailscale is the encrypted path from outside (R20). Port 80 must never be forwarded.
- The Arrs share LXC 210 and resolve each other by Docker service name on Compose's own network, not via Pi DNS.
