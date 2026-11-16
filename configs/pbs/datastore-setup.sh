#!/usr/bin/env bash
# datastore-setup.sh — RUN ON THE PBS VM. Deliberately self-contained (the rest of
# the repo isn't on the PBS VM — copy just this one file over). Creates the datastore
# and sets retention. NEVER keep-all. [R4 R6]
set -euo pipefail

DATASTORE_PATH="<DATASTORE_PATH>"   # ENTER: e.g. /mnt/datastore/backups (where the USB HDD mounts in the VM)
[[ "$DATASTORE_PATH" == *"<"* ]] && { echo "!! ENTER DATASTORE_PATH first" >&2; exit 1; }

DATASTORE=backups

# 1. Datastore ---------------------------------------------------------------
if proxmox-backup-manager datastore list 2>/dev/null | grep -qw "$DATASTORE"; then
  echo "datastore '$DATASTORE' already exists."
else
  proxmox-backup-manager datastore create "$DATASTORE" "$DATASTORE_PATH"
fi

# 2 + 3. Retention + GC. Prune only MARKS snapshots removable; garbage-collection
# is what frees the chunks. You need both, and never keep-all (R4 R6).
proxmox-backup-manager datastore update "$DATASTORE" --gc-schedule 'daily 03:30'
if proxmox-backup-manager prune-job list 2>/dev/null | grep -qw "${DATASTORE}-prune"; then
  proxmox-backup-manager prune-job update "${DATASTORE}-prune" \
    --keep-daily 7 --keep-weekly 4 --keep-monthly 6
else
  proxmox-backup-manager prune-job create "${DATASTORE}-prune" \
    --store "$DATASTORE" --schedule 'daily 02:00' \
    --keep-daily 7 --keep-weekly 4 --keep-monthly 6
fi
echo "datastore '$DATASTORE' ready: GC daily 03:30, prune daily 02:00 (7d / 4w / 6m)."

# 4. Encryption is CLIENT-side in PBS — there is no datastore toggle here. Create the
#    key ON EACH PVE HOST (nuc1/nuc2), where backups originate:
#      proxmox-backup-client key create /etc/pve/priv/pbs-enc.key
#    SAVE: that key is the ONLY way to read encrypted backups — copy it to your vault
#    (R21). Lost key = unreadable backups even with the datastore fully intact.
