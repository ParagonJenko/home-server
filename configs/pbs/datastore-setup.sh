#!/usr/bin/env bash
# datastore-setup.sh — RUN ON THE PBS VM. Deliberately self-contained (the rest of
# the repo isn't on the PBS VM — copy just this one file over). Creates the datastore
# and sets retention. NEVER keep-all. [R4 R6]
set -euo pipefail

DATASTORE_PATH="<DATASTORE_PATH>"   # ENTER: e.g. /mnt/datastore/backups (where the USB HDD mounts in the VM)
[[ "$DATASTORE_PATH" == *"<"* ]] && { echo "!! ENTER DATASTORE_PATH first" >&2; exit 1; }

# TODO: proxmox-backup-manager datastore create backups "$DATASTORE_PATH"
# TODO: set prune: keep-daily=7 keep-weekly=4 keep-monthly=6
# TODO: schedule prune + garbage-collection (prune frees nothing without GC)
# TODO: enable datastore encryption; the key it prints is a SAVE → vault (R21)
echo "datastore-setup: ENTER DATASTORE_PATH above, then implement the TODOs (rules.md G3)."
