#!/usr/bin/env bash
# run-arr-setup.sh — run arr-setup.py INSIDE the media-pipeline LXC (210) from the Proxmox
# host (nuc1). Inside the container the Arr APIs are on localhost and Bazarr's config.yaml is
# on disk, so none of the SONARR_URL/BAZARR_API_KEY overrides are needed — it "just works".
#
#   ./run-arr-setup.sh            # dry run, in the container
#   ./run-arr-setup.sh --apply    # write, in the container
#
# The .env lives here on the host (gitignored, source of truth). First-time credential entry
# is interactive and only works on the host, so if keys are missing run `python3 arr-setup.py`
# here once to fill .env (its API calls will fail on localhost — that's fine, it still saves the
# keys), then use this wrapper. This wrapper stages .env into the container, runs there, pulls
# back any keys the run added, and wipes the container copy.
set -euo pipefail

CTID="${MEDIA_CTID:-210}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="/root/.arr-setup"   # transient staging dir inside the container

command -v pct >/dev/null || { echo "pct not found — run this on the Proxmox host (nuc1), not in a container"; exit 1; }
pct status "$CTID" 2>/dev/null | grep -q running || { echo "LXC $CTID is not running"; exit 1; }
pct exec "$CTID" -- sh -c 'command -v python3 >/dev/null' \
  || { echo "python3 missing in LXC $CTID — install it there: pct exec $CTID -- apt-get install -y python3"; exit 1; }

cleanup() { pct exec "$CTID" -- rm -rf "$DEST" 2>/dev/null || true; }
trap cleanup EXIT

pct exec "$CTID" -- mkdir -p "$DEST"
pct push "$CTID" "$HERE/arr-setup.py" "$DEST/arr-setup.py"
[ -f "$HERE/.env" ] && pct push "$CTID" "$HERE/.env" "$DEST/.env"

# Run in the container. Keys already in .env -> no prompt; it connects over localhost.
pct exec "$CTID" -- python3 "$DEST/arr-setup.py" "$@"

# Keep the host .env in sync with anything the run saved (e.g. the generated Arr WebUI login).
pct pull "$CTID" "$DEST/.env" "$HERE/.env" 2>/dev/null || true
echo "done (ran inside LXC $CTID)"
