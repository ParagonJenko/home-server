#!/usr/bin/env bash
# _tailscale-tun.sh — give an unprivileged LXC access to /dev/net/tun so Tailscale
# can run inside it (unprivileged containers have no tun device by default). [R20]
set -euo pipefail

apply_tailscale_tun() {
  # usage: apply_tailscale_tun <CTID>
  local ctid="$1"
  local conf="/etc/pve/lxc/${ctid}.conf"
  grep -q 'dev/net/tun' "$conf" || cat >> "$conf" <<'EOF'
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
  echo "apply_tailscale_tun ${ctid}: tun device bound"
}
