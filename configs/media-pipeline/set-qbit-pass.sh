#!/usr/bin/env bash
# set-qbit-pass.sh — run on the NUC-1 HOST, on its own line. Prompts (hidden) for the
# qBittorrent WebUI 'admin' password and writes it into LXC 210's .env. The value is
# read from /dev/tty and piped to the container over stdin, so it never lands in shell
# history or the process list (unlike `sed -i s/.../PASS/`).
#   ./configs/media-pipeline/set-qbit-pass.sh [CTID]
set -euo pipefail
CTID="${1:-210}"

read -rsp "qBittorrent password (the one you just set in the WebUI): " QBP </dev/tty; echo
[ -n "$QBP" ] || { echo "nothing entered — .env unchanged"; exit 0; }

# grep drops any existing QBIT_PASS line; cat appends the new one from stdin.
printf 'QBIT_PASS=%s\n' "$QBP" | pct exec "$CTID" -- bash -c '
  f=/opt/media-pipeline/.env
  { grep -v "^QBIT_PASS=" "$f" 2>/dev/null; cat; } > "$f.new" && mv "$f.new" "$f"'

echo "QBIT_PASS written to ${CTID}:/opt/media-pipeline/.env"
