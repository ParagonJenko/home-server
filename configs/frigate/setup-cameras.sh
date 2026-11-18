#!/usr/bin/env bash
# setup-cameras.sh — interactive Frigate camera setup. Names the placeholder cameras to your real
# rooms (keeping config.yaml, network.md and prometheus.yml in sync so DNS, recording and the
# up/down probes all agree) and sets the one shared Eufy RTSP credential. Run from the repo on any
# box; it edits REPO files, so commit + pull on nuc2/Pi, then deploy. No secrets are committed. [R13 R21]
set -euo pipefail
cd "$(dirname "$0")"                       # configs/frigate
CFG=config.yaml
NET=../../network.md
PROM=../pi/prometheus/prometheus.yml
ENVF=.env

echo "== Frigate camera setup =="
echo
echo "FIRST, in the Eufy app, enable RTSP on each indoor cam (cam → Settings → RTSP) using the SAME"
echo "username + password on all of them. (Battery doorbell is NOT a Frigate cam — it goes through the"
echo "eufy_security integration; see runbooks/eufy-ha.md.)"
read -rp "Ready? [Enter to continue, Ctrl-C to abort] " _

# --- 1. Name the cameras ---------------------------------------------------
mapfile -t cams < <(grep -oE '^    cam-[a-z0-9-]+:' "$CFG" | tr -d ' :')
[ ${#cams[@]} -gt 0 ] || { echo "No 'cam-*' streams found in $CFG — nothing to rename." >&2; exit 1; }

echo
echo "Current cameras: ${cams[*]}"
echo "Enter the real room for each (lowercase slug, e.g. hallway, office, landing) — blank keeps it."
for c in "${cams[@]}"; do
  old="${c#cam-}"
  read -rp "  cam-${old}  →  cam-" new
  new="$(printf '%s' "$new" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')"
  if [ -n "$new" ] && [ "$new" != "$old" ]; then
    for f in "$CFG" "$NET" "$PROM"; do
      [ -f "$f" ] && sed -i "s/cam-${old}\b/cam-${new}/g" "$f"
    done
    echo "    renamed cam-${old} → cam-${new}  (config.yaml, network.md, prometheus.yml)"
  fi
done

# --- 2. RTSP credentials (shared by all cameras) ---------------------------
echo
setcreds=1
if grep -q '^FRIGATE_RTSP_PASSWORD=.' "$ENVF" 2>/dev/null; then
  read -rp "RTSP credentials already set in .env. Replace them? [y/N] " a
  [[ "$a" =~ ^[Yy]$ ]] || setcreds=0
fi
if [ "$setcreds" = 1 ]; then
  read -rp  "  Eufy RTSP username: " u
  read -rsp "  Eufy RTSP password: " p; echo
  tmp="$(mktemp)"
  grep -v -E '^FRIGATE_RTSP_(USER|PASSWORD)=' "$ENVF" 2>/dev/null > "$tmp" || :
  { cat "$tmp"; printf 'FRIGATE_RTSP_USER=%s\nFRIGATE_RTSP_PASSWORD=%s\n' "$u" "$p"; } > "$ENVF"
  rm -f "$tmp"; chmod 600 "$ENVF"
  echo "  saved to configs/frigate/.env (gitignored, chmod 600)"
fi

# --- 3. Commit the (non-secret) renames, if any ----------------------------
# .env is gitignored, so there's nothing to commit unless a camera was actually renamed.
REPO="$(git -C . rev-parse --show-toplevel 2>/dev/null || true)"
files=(configs/frigate/config.yaml network.md configs/pi/prometheus/prometheus.yml)
echo
if [ -n "$REPO" ] && [ -n "$(git -C "$REPO" status --porcelain -- "${files[@]}" 2>/dev/null)" ]; then
  git -C "$REPO" status --short -- "${files[@]}"
  read -rp "Commit + push these renames now? [Y/n] " a
  if [[ ! "$a" =~ ^[Nn]$ ]]; then
    git -C "$REPO" add -- "${files[@]}"
    git -C "$REPO" commit -q -m "frigate: name cameras to real rooms" && git -C "$REPO" push && echo "  committed + pushed."
  fi
else
  echo "No repo changes to commit — you kept the camera names (the RTSP creds are gitignored)."
fi

cat <<'EOF'

Deploy (run on each box — these can't be done from here):
  # Pi — push DNS rewrites so the camera names resolve before Frigate starts:
  cd ~/home-server && git pull && ./configs/pi/adguard-rewrites.py --apply
  # NUC-2 — (re)deploy Frigate (no re-prompt; creds are set):
  cd ~/home-server && git pull && ./configs/lxc/frigate.sh && ./configs/frigate/verify-frigate.sh

Then: HA → add the Frigate integration, re-run the /api/states dump, and the dashboard
Security tab gets the real camera cards.
EOF
