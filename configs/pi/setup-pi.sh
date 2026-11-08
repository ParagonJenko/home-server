#!/usr/bin/env bash
# setup-pi.sh — base the Pi (F2). Run as root. Base packages, timezone, Docker,
# SD-card write reductions, stack directories. Stops short of bringing the stack up
# (that needs secrets) and prints the remaining steps.
set -euo pipefail

apt update && apt -y install ca-certificates curl git
curl -fsSL https://get.docker.com | sh

# SD-card longevity: cards die from write volume, not age.
# journald volatile (logs do NOT survive reboot — set back to persistent to chase a crash):
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=volatile\n' > /etc/systemd/journald.conf.d/volatile.conf
# swap off:
systemctl disable --now dphys-swapfile 2>/dev/null || true

mkdir -p /opt/pi-stack /opt/monitoring
echo "setup-pi done. Next: copy configs/pi -> /opt/pi-stack, configs/monitoring -> /opt/monitoring,"
echo "cp .env.example .env + alertmanager/discord-webhook-url.example -> real (chmod 600), then F3."
