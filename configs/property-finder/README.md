# property-finder (LXC 260, nuc1)

Personal project — [ParagonJenko/local-property-finder](https://github.com/ParagonJenko/local-property-finder) (**private**).
Scrapes rental/buy listings on a schedule, stores them in SQLite, React UI + Discord alerts. Personal use, LAN only.

| | |
|---|---|
| Create / update | `./configs/lxc/property-finder.sh` (re-run = `git pull` + rebuild) |
| UI | `https://property.home.alexjenkinson.com` → `property-lxc.home.alexjenkinson.com:3000` (frontend proxies `/api` to `:3001`) |
| In the CT | `/opt/local-property-finder` (the project clone); data + `config.yaml` in `data/` |
| Health | `pct exec 260 -- bash /opt/local-property-finder/verify-property.sh` |
| Manual scrape | `pct exec 260 -- curl -X POST http://localhost:3001/api/v1/admin/trigger-scrape` |
| Reload config | `pct exec 260 -- bash -c 'cd /opt/local-property-finder && docker compose restart api scraper'` |

## Repo access

The repo is private. On first run the script generates a key **inside the CT** (`/root/.ssh/lpf_deploy`), prints the
public half, and waits while you add it as a **read-only deploy key** on the repo. Boxes pull, never push. To revoke:
delete the key on GitHub (Settings → Deploy keys).

## Per-box files (gitignored — never commit, R21)

| File here | Goes to (in the CT) | What |
|---|---|---|
| `config.yaml` (from the project's `config.yaml.example`) | `data/config.yaml` | Areas, tiers, **Discord webhook URLs** |
| `.env` (optional, from `.env.example`) | `.env` | Only if you change the defaults; holds `HEALTH_CHECK_WEBHOOK_URL` |

Keep both in the vault too. The script won't start the stack until a `config.yaml` exists.

The SQLite DB lives in the CT rootfs, so it's covered by the PBS backup of CT 260.
