# Home Assistant config in the repo

HA (VM 910, `192.168.1.25`) keeps its brain — automations, helpers, dashboards — inside the VM's
`.storage`/`/config`, not in git by default. That's the one part of the stack a catastrophe couldn't
rebuild from the repo. These files close that gap: HA's config is now diffable and reproducible like
every LXC.

## What's here

| File | What it is |
|---|---|
| `haos-vm.sh` | Creates the HAOS VM (910). |
| `ha-config.sh` | Manage HA from the NUC-2 host over SSH into HAOS (status, port, restart, view config). |
| `verify-ha.sh` | Health check. |
| `dashboards/home.json` | The 6-view Mushroom dashboard. Deployed live via HA-MCP (`ha_config_set_dashboard`). |
| `automations.yaml` | The automations, deployed live via HA-MCP and committed here as the source of truth. |
| `helpers.yaml` | Reference export of zones + persons (registry-managed; diffable record, not auto-loaded). |
| `prometheus-snippet.yaml` | HA scrape config for the Pi's Prometheus. |

HA-MCP itself (how Claude reads/writes HA directly) is documented in `runbooks/ha-mcp-cloudflared.md`.

## Two restore paths

1. **HA backup tarball — full + fast.** HA's own encrypted backup restores *everything* (config, DB,
   add-ons) in one shot. Latest grabbed 2026-11-18: `42393ae3` (full + all add-ons). Keep the backup
   **encryption key** in the password manager — without it a backup can't be restored.
2. **This repo — granular + diffable.** Survives even if backups are lost, and shows *what changed*.
   Dashboards redeploy via HA-MCP; `automations.yaml` can drop into `/config/automations.yaml`.

## How automations get here

Authored and deployed **live via HA-MCP**, then exported to `automations.yaml` as the source of truth.
They currently load from HA's UI-managed store. To make this repo file the *live* source on a rebuild:
push it with `ha-config.sh` (SSH into HAOS) to `/config/automations.yaml` and ensure
`automation: !include automations.yaml` is in `configuration.yaml`. (Not wired as the live include yet —
the backup tarball is the current fast-restore path.)

## Current automations

- **Doorbell → phone (snapshot)** — ring pushes a live doorbell snapshot to Alex's phone.
- **Person detected while away** — Frigate person in any room while away → alert with that room's snapshot.
- **Arrive home (dark) → living room lights** — home after sunset turns the living room on.
- **Leave home → all lights off** — away for 2 min turns every light off (single occupant).
