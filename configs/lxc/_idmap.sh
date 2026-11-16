#!/usr/bin/env bash
# _idmap.sh — map container UID/GID 1000 to host 1000 so the shared `media` user
# can read/write the mergerfs pool across every container. Sourced by app scripts.
set -euo pipefail

apply_idmap() {
  # usage: apply_idmap <CTID>   (unprivileged container)
  local ctid="$1"
  local conf="/etc/pve/lxc/${ctid}.conf"
  [ -e "$conf" ] || { echo "apply_idmap: $conf not found"; return 1; }

  if grep -q '^lxc.idmap: u 1000 1000 1' "$conf"; then
    echo "apply_idmap ${ctid}: already mapped"; return 0
  fi

  # map everything through the usual unprivileged offset, except uid/gid 1000
  # which maps straight to host 1000 (the shared media user).
  cat >> "$conf" <<'EOF'
lxc.idmap: u 0 100000 1000
lxc.idmap: g 0 100000 1000
lxc.idmap: u 1000 1000 1
lxc.idmap: g 1000 1000 1
lxc.idmap: u 1001 101001 64535
lxc.idmap: g 1001 101001 64535
EOF

  # root must be allowed to use host uid/gid 1000 for the container
  grep -q '^root:1000:1$' /etc/subuid || echo 'root:1000:1' >> /etc/subuid
  grep -q '^root:1000:1$' /etc/subgid || echo 'root:1000:1' >> /etc/subgid

  echo "apply_idmap ${ctid}: container 1000 -> host 1000"
}
