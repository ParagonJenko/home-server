#!/usr/bin/env bash
# _template.sh — resolve the current Debian 13 LXC template locally, discovered
# live via `pveam available` rather than a hardcoded filename (the point release
# drifts: 13.0-1, 13.1-2, …). Sourced by every pct-create script.
set -euo pipefail

resolve_template() {
  # prints the local template volid, downloading it if missing
  local name
  name="$(pveam available --section system | awk '/debian-13/{print $2}' | sort -V | tail -1)"
  require_filled "template name" "$name"
  pveam list local | grep -q "$name" || pveam download local "$name"
  echo "local:vztmpl/${name}"
}
