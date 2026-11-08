#!/usr/bin/env bash
# offsite-sync.sh — push the PBS datastore to encrypted cloud object storage
# (Backblaze B2 / S3 via rclone, or a remote PBS). Scheduled daily after the backup
# window. Without this the only copy is the single USB HDD in the same room (R4 R17). [R3]
set -euo pipefail

# rclone config lives in ~/.config/rclone/rclone.conf (GITIGNORED — holds the remote creds).
# Use a crypt remote over the cloud remote so the provider never sees plaintext.
# The crypt key is a secret → vault (R21). Lose it and the offsite copy is unrecoverable.
#
# TODO: rclone sync /mnt/datastore/backups crypt:home-server-pbs --fast-list --transfers 4
# TODO: wrap in a systemd timer (offsite-sync.timer) firing after the backup window.
# VERIFY: a test restore must pull a container FROM THE CLOUD COPY (not the USB HDD).
echo "offsite-sync: configure rclone crypt remote + timer (rules.md E7)."
