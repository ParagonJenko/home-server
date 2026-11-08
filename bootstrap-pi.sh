#!/usr/bin/env bash
# bootstrap-pi.sh — one command for the Raspberry Pi.
# Stage D (DNS) now; Stage H (monitoring) after the containers exist. Run as root.
set -euo pipefail
cd "$(dirname "$0")"
source configs/lib/common.sh
need_root

echo "=== Pi bootstrap ==="
pause "Prereq: Pi OS Lite (64-bit) imaged, SSH in, static IP 192.168.1.4 set (Stage D1)."

echo "--- Stage D: internal DNS ---"
run ./configs/pi/setup-pi.sh                       # D2: base, Docker, SD-card tuning
./secrets-init.sh                                  # Grafana password + Discord webhook (gitignored)
run bash -c 'cd configs/pi && docker compose up -d adguardhome'   # D3: AdGuard first
pause "AdGuard wizard at http://<pi>:3000 — set the admin UI to port 8081."
run bash -c 'cd configs/pi && python3 adguard-rewrites.py --apply'   # push rewrites from network.md
echo "Point the Pi at its own resolver (127.0.0.1) — see configs/pi/setup-pi.sh notes."

echo
echo ">> Stage H (monitoring) comes AFTER the containers exist and their MACs are reserved."
confirm "Are NUC-1 and NUC-2 built (media + Frigate running)?" || { echo "Come back for Stage H later."; exit 0; }

echo "--- Stage H: monitoring & alerting ---"
run bash -c 'cd configs/pi && docker compose up -d'   # H1: full stack
pause "On BOTH NUCs: install node_exporter + thin-pool/SMART exporters (H2/J3)."
run bash -c 'cd configs/pi && docker compose exec alertmanager amtool alert add alertname=TestAlert severity=warning instance=pi --alertmanager.url=http://localhost:9093'
echo "=== Pi done. Check the alert reached Discord. ==="
