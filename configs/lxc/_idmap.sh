#!/usr/bin/env bash
# _idmap.sh — map container UID/GID 1000 to host 1000 so the shared `media` user
# can read/write the mergerfs pool across every container. Sourced by app scripts.
set -euo pipefail

apply_idmap() {
  # usage: apply_idmap <CTID>
  local ctid="$1"
  local conf="/etc/pve/lxc/${ctid}.conf"
  # TODO: append the lxc.idmap lines that carve out uid/gid 1000 → host 1000.
  # Example shape (unprivileged container):
  #   lxc.idmap: u 0 100000 1000
  #   lxc.idmap: g 0 100000 1000
  #   lxc.idmap: u 1000 1000 1
  #   lxc.idmap: g 1000 1000 1
  #   lxc.idmap: u 1001 101001 64535
  #   lxc.idmap: g 1001 101001 64535
  # and the matching /etc/subuid /etc/subgid entries for root.
  echo "apply_idmap ${ctid}: TODO — see comment in $conf"
}
