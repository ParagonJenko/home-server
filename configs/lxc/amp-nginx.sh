#!/usr/bin/env bash
# amp-nginx.sh — LXC 230 (AMP) and LXC 240 (Nginx). Native installs, no Docker,
# so NO --features flags. Neither needs the media mount. [R13 R19 R20]
set -euo pipefail
cd "$(dirname "$0")"
source ./_require_filled.sh; source ./_template.sh

# AMP (230): install via CubeCoders' own installer inside the container (vendor-managed,
#   not worth pinning). Add amp.home to network.md's DNS table when installed.
# Nginx (240): uses ../nginx/homelab.conf. Set the resolver line before `nginx -t`.
#   A passing `nginx -t` does NOT mean routing works — the resolver is only consulted
#   at request time, so without the Pi every proxied hostname 502s while the config tests clean.
echo "amp-nginx: create 230 + 240, install AMP, deploy ../nginx/homelab.conf (fill the resolver)."
