#!/usr/bin/env bash
# datastore-setup.sh — RUN ON THE PBS VM. Deliberately self-contained (the rest of
# the repo isn't on the PBS VM — copy just this one file over). Creates the datastore
# and sets retention. NEVER keep-all. [R4 R6]
set -euo pipefail

DATASTORE_PATH="<DATASTORE_PATH>"   # e.g. /mnt/datastore/backups (where the USB HDD mounts in the VM)
[[ "$DATASTORE_PATH" == *"<"* ]] && { echo "!! fill DATASTORE_PATH" >&2; exit 1; }

# TODO: proxmox-backup-manager datastore create backups "$DATASTORE_PATH"
# TODO: set prune: keep-daily=7 keep-weekly=4 keep-monthly=6
# TODO: schedule prune + garbage-collection (prune frees nothing without GC)
# TODO: enable datastore encryption; the key is a secret → vault (R21)
echo "datastore-setup: fill DATASTORE_PATH and the TODOs (rules.md E4)."
