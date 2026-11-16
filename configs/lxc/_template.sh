#!/usr/bin/env bash
# _template.sh — resolve the current Debian 13 LXC template locally, discovered
# live via `pveam available` rather than a hardcoded filename (the point release
# drifts: 13.0-1, 13.1-2, …). Sourced by every pct-create script.
set -euo pipefail

resolve_template() {
  # prints the local template volid, downloading it if missing.
  # MUST match the host CPU arch: both _amd64 and _arm64 variants are listed for
  # the same release, and a bare `sort -V | tail -1` picks arm64 (it sorts after
  # amd64) — which boots fine on the ARM Pi but dies with "Exec format error" on
  # the x86 NUCs. dpkg's arch name (amd64 / arm64) is exactly the filename token.
  local arch name
  arch="$(dpkg --print-architecture)"
  name="$(pveam available --section system | awk '{print $2}' \
            | grep -E "debian-13.*_${arch}\.tar" | sort -V | tail -1)"
  require_filled "debian-13 template for ${arch}" "$name"
  # download output must go to stderr: this function's stdout is captured with
  # $(resolve_template), and pveam's progress text would otherwise be concatenated
  # into the volid (ostemplate > 255 chars). Only the echo below belongs on stdout.
  pveam list local | grep -q "$name" || pveam download local "$name" >&2
  echo "local:vztmpl/${name}"
}
