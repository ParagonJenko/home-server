#!/usr/bin/env bash
# _require_filled.sh — guard against running a script with placeholders still in it.
# Sourced by the stage scripts. Fails loudly if a value looks like a template.
set -euo pipefail

require_filled() {
  # usage: require_filled VARNAME "$VAR"
  local name="$1" val="${2-}"
  if [[ -z "$val" || "$val" == *"<"*">"* || "$val" == *"{{"*"}}"* || "$val" == "CHANGEME" ]]; then
    echo "!! $name is still a placeholder ($val) — fill it before running." >&2
    exit 1
  fi
}

require_block_device() {
  # usage: require_block_device /dev/sdX  — proves the device exists before anything destructive
  local dev="$1"
  require_filled "device" "$dev"
  [[ -b "$dev" ]] || { echo "!! $dev is not a block device — refusing." >&2; exit 1; }
}
