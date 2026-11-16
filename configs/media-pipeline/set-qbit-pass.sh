#!/usr/bin/env bash
# set-qbit-pass.sh — run on the NUC-1 HOST, on its own line. Records the qBittorrent
# WebUI password (the one YOU set in the browser) into LXC 210's .env so arr-setup and
# qbit_manage can log in. Reads from /dev/tty and pipes the value to the container over
# stdin, so it never lands in shell history or the process list.
#   ./configs/media-pipeline/set-qbit-pass.sh [CTID]
set -euo pipefail
CTID="${1:-210}"

read -rsp "qBittorrent password you set in the WebUI (user: admin): " QBP </dev/tty; echo
[ -n "$QBP" ] || { echo "nothing entered — .env unchanged"; exit 0; }

printf 'QBIT_USER=admin\nQBIT_PASS=%s\n' "$QBP" | pct exec "$CTID" -- bash -c '
  f=/opt/media-pipeline/.env
  { grep -vE "^QBIT_(USER|PASS)=" "$f" 2>/dev/null; cat; } > "$f.new" && mv "$f.new" "$f"'

echo "qBittorrent credentials written to ${CTID}:/opt/media-pipeline/.env"
