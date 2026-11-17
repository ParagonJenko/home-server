#!/usr/bin/env bash
# offsite-sync.sh — push the PBS datastore to encrypted cloud object storage
# (Backblaze B2 / S3 via rclone, or a remote PBS). Scheduled daily after the backup
# window. Without this the only copy is the single USB HDD in the same room (R4 R17). [R3]
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"   # loads ~/.homelab.env -> OFFSITE_REMOTE set by offsite-setup.sh

# rclone config lives in ~/.config/rclone/rclone.conf (GITIGNORED — holds the remote creds).
# Use a crypt remote over the cloud remote so the provider never sees plaintext.
# The crypt key is a secret → vault (R21). Lose it and the offsite copy is unrecoverable.
#
# VERIFY: a test restore must pull a container FROM THE CLOUD COPY (not the USB HDD).

REMOTE="${OFFSITE_REMOTE:-crypt:home-server-pbs}"   # a crypt remote wrapping your cloud remote
SRC="${DATASTORE_PATH:-/mnt/datastore/backups}"

run_sync() {
  command -v rclone >/dev/null || { echo "!! rclone not installed (apt install rclone)" >&2; exit 1; }
  [ -d "$SRC" ] || { echo "!! $SRC not found — is the datastore mounted?" >&2; exit 1; }
  rclone sync "$SRC" "$REMOTE" --fast-list --transfers 4 --log-level INFO
  echo "offsite sync complete: $SRC -> $REMOTE"
}

install_timer() {
  local self; self="$(readlink -f "$0")"
  cat > /etc/systemd/system/offsite-sync.service <<EOF
[Unit]
Description=Offsite sync of the PBS datastore to encrypted cloud storage
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${self} --run
EOF
  cat > /etc/systemd/system/offsite-sync.timer <<'EOF'
[Unit]
Description=Daily offsite sync, after the backup/prune/GC window

[Timer]
OnCalendar=*-*-* 05:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now offsite-sync.timer
  echo "offsite-sync.timer installed (daily 05:00, after the 02:00 prune / 03:30 GC)."
}

case "${1:-}" in
  --run)           run_sync ;;
  --install-timer) install_timer ;;
  *) echo "usage: $0 --run | --install-timer"
     echo "  remote: $REMOTE   source: $SRC"
     echo "  ENTER: set up the rclone crypt remote first (rclone config); the crypt key is a SAVE -> vault (R21)."
     exit 1 ;;
esac
