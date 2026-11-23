# social-generator (LXC 250, nuc1)

Personal project — [ideaSquared/social-generator](https://github.com/ideaSquared/social-generator). Renders the
**Social posts** sheet into carousels, cards and videos on a timer, and serves the review page.

| | |
|---|---|
| Create / update | `./configs/lxc/social-generator.sh` (re-run = `git pull` + rebuild) |
| Review page | `https://social.home.alexjenkinson.com` → `social-lxc.home.alexjenkinson.com:8087` |
| In the CT | `/opt/social-generator` (the project clone); compose lives in `deploy/` |
| Health | `pct exec 250 -- bash /opt/social-generator/verify-social.sh` |
| Logs | `pct exec 250 -- bash -c 'cd /opt/social-generator/deploy && docker compose logs -f runner'` |

## Per-box files (gitignored — never commit, R21)

| File here | Goes to (in the CT) | What |
|---|---|---|
| `.env` (from `.env.example`) | `deploy/.env` | `SHEET_ID` etc. |
| `secrets/service-account.json` | `deploy/secrets/service-account.json` | Google service account key. Share the sheet with its email as **Editor** so it can fill in "Assets made" |

Keep both in the vault too. The script won't start the stack until a sheet source exists (a key + `SHEET_ID`, or `SHEET_CSV_URL`).

The review page shows unpublished drafts — LAN only (split-horizon DNS, no port forward), same as everything else.
