#!/usr/bin/env bash
# setup-cameras.sh — store the shared Eufy RTSP credential in the gitignored .env. Nothing is
# committed or pushed: the boxes pull only, so secrets stay on the box (R21) and any config/name
# change is made in the repo from the session and pulled. Run on NUC-2, then deploy with frigate.sh.
#
# To RENAME the cameras to your real rooms: the name lives in three tracked files (config.yaml,
# network.md, prometheus.yml) and must be pushed, which a box can't do — so tell Claude the rooms
# and it edits + pushes them; you then `git pull`. (Placeholders: living-room/kitchen/bedroom/basement.)
set -euo pipefail
cd "$(dirname "$0")"                       # configs/frigate
ENVF=.env

echo "== Eufy RTSP credentials =="
echo "Enable RTSP on each indoor cam in the Eufy app first (cam → Settings → RTSP), SAME user/pass"
echo "on all 4. (The battery doorbell is NOT a Frigate cam — see runbooks/eufy-ha.md.)"
echo
if grep -q '^FRIGATE_RTSP_PASSWORD=.' "$ENVF" 2>/dev/null; then
  read -rp "RTSP creds already set. Replace them? [y/N] " a
  [[ "$a" =~ ^[Yy]$ ]] || { echo "Keeping existing creds. Deploy with ./configs/lxc/frigate.sh"; exit 0; }
fi
read -rp  "  Eufy RTSP username: " u
read -rsp "  Eufy RTSP password: " p; echo
[ -n "$p" ] || { echo "No password given — aborting." >&2; exit 1; }

tmp="$(mktemp)"
grep -v -E '^FRIGATE_RTSP_(USER|PASSWORD)=' "$ENVF" 2>/dev/null > "$tmp" || :
{ cat "$tmp"; printf 'FRIGATE_RTSP_USER=%s\nFRIGATE_RTSP_PASSWORD=%s\n' "$u" "$p"; } > "$ENVF"
rm -f "$tmp"; chmod 600 "$ENVF"
echo "  saved to configs/frigate/.env (gitignored)."

cat <<'EOF'

Deploy:
  # Pi — DNS rewrites so the camera names resolve before Frigate starts:
  cd ~/home-server && git pull && ./configs/pi/adguard-rewrites.py --apply
  # NUC-2 — deploy Frigate:
  cd ~/home-server && git pull && ./configs/lxc/frigate.sh && ./configs/frigate/verify-frigate.sh
EOF
