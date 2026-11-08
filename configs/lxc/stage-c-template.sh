#!/usr/bin/env bash
# stage-c-template.sh — download the current Debian 13 LXC template (C1).
# Run as root on each host that creates containers (NUC-1 and NUC-2). [R19]
set -euo pipefail
source "$(dirname "$0")/_require_filled.sh"
source "$(dirname "$0")/_template.sh"

TEMPLATE="$(resolve_template)"
echo "Template ready: ${TEMPLATE}"
pveam list local
