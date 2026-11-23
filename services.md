# services.md

The service map and the Nginx routing table. Every proxied service has two DNS names: a **front** name that resolves to Nginx, and a **backend** name that resolves to the container itself (so Nginx doesn't loop back to itself).

## Service map

| Service | Host | Guest | Port(s) | Proxied? |
|---|---|---|---|---|
| Nginx (reverse proxy) | nuc1 | LXC 240 | 80 | — (is the proxy) |
| qBittorrent | nuc1 | LXC 210 | 8080 | via front name |
| Sonarr / Radarr / Bazarr / Prowlarr | nuc1 | LXC 210 | 8989 / 7878 / 6767 / 9696 | via front names |
| FlareSolverr | nuc1 | LXC 210 | 8191 | internal only |
| Maintainerr | nuc1 | LXC 210 | 6246 | reached directly (add a front name later) |
| Tdarr | nuc1 | LXC 210 | 8265 (UI), 8266 (node) | reached directly |
| maintainerr-keeper (Discord bot) | nuc1 | LXC 210 | — (outbound gateway only) | — |
| Plex | nuc1 | LXC 220 | 32400 | via front name |
| AMP | nuc1 | LXC 230 | TBD | — |
| property-finder (personal project) | nuc1 | LXC 260 | 3000 (UI), 3001 (API) | via front name (UI; it proxies `/api` itself) |
| Frigate | nuc2 | LXC 111 | 8971 (auth UI), 5000 (**unauth — never expose**) | via front name |
| Home Assistant | nuc2 | VM 910 | 80 | — (direct; serves on :80 from a restored config, HAOS default is 8123) |
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
| `plex.home.alexjenkinson.com` | `plex-lxc.home.alexjenkinson.com:32400` |
| `frigate.home.alexjenkinson.com` | `frigate-lxc.home.alexjenkinson.com:8971` |
| `sonarr.home.alexjenkinson.com` | `media-pipeline.home.alexjenkinson.com:8989` |
| `radarr.home.alexjenkinson.com` | `media-pipeline.home.alexjenkinson.com:7878` |
| `bazarr.home.alexjenkinson.com` | `media-pipeline.home.alexjenkinson.com:6767` |
| `prowlarr.home.alexjenkinson.com` | `media-pipeline.home.alexjenkinson.com:9696` |
| `property.home.alexjenkinson.com` | `property-lxc.home.alexjenkinson.com:3000` |

## Notes

- The proxy serves **HTTPS on 443** with a Let's Encrypt **wildcard cert for `*.home.alexjenkinson.com`** (issued by `configs/nginx/enable-tls.sh` via Cloudflare DNS-01, auto-renewed by acme.sh). Port 80 redirects to 443. The names resolve only on the LAN (split-horizon via AdGuard) and nothing is port-forwarded; Tailscale remains the path from outside (R20).
- nginx→backend hops stay plain HTTP on the LAN — TLS terminates at the proxy. Home Assistant (`:80` here) and AMP are reached directly, not through nginx, so they're not covered by the wildcard yet.
- The Arrs share LXC 210 and resolve each other by Docker service name on Compose's own network, not via Pi DNS.
