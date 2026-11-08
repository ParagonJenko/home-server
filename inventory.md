# inventory.md

Physical hardware. Addresses live in `network.md`, disk identity in `storage.md`.

## Compute

| Role | Box | Notes |
|---|---|---|
| NUC-1 | Beelink S13 | Proxmox host — media stack (Stages B–D). DAS attached here. |
| NUC-2 | Beelink S12 Pro | Proxmox host — Frigate + PBS (Stage E). USB HDD attached here. |
| Pi | Raspberry Pi 4/5 + microSD | DNS + monitoring/alerting (Stage F). Sole DNS; boots first. |

## Storage

| Device | Where | Role |
|---|---|---|
| 2×4TB DAS | NUC-1 | mergerfs media pool (~7.2T usable) |
| 2TB USB HDD | NUC-2 | PBS datastore (block device to VM 900) |
| Internal SSDs | each NUC | Proxmox root + local-lvm |

## Network & power

| Device | Notes |
|---|---|
| Managed switch | The single internal uplink point (R16) |
| Access point(s) | DHCP-issued DNS must be the Pi (R14) |
| UPS | Powers both NUCs, DAS, Pi, USB HDD; NUT graceful shutdown (R22) |
| ISP router | Gateway/DHCP for now; to be replaced by a dedicated router (R15) |

## Cameras

| Device | Notes |
|---|---|
| 4× Eufy cameras | RTSP to Frigate, addressed by name. **No HomeBase** — confirm each model does standalone RTSP (many Eufy models need a HomeBase for RTSP). |

## Future / optional

| Device | Notes |
|---|---|
| GPU node | For local LLM inference (Stage I) — e.g. a used RTX 3090 (24GB) in a Proxmox node, or a unified-memory Mac. Not yet owned. |
