#!/usr/bin/env bash
# gather-keeper-creds.sh — prompt for the maintainerr-keeper Discord bot token + channel id ONE
# BY ONE and write them into LXC 210's /opt/media-pipeline/.env (gitignored, off-repo R21), then
# restart the bot. Run as root on NUC-1. Re-runnable: it only asks to replace a value that exists.
set -euo pipefail
CTID=210
ENVF=/opt/media-pipeline/.env

[ "$(id -u)" -eq 0 ] || { echo "Run as root (needs pct)." >&2; exit 1; }
command -v pct >/dev/null || { echo "pct not found — run this on the Proxmox host (nuc1)." >&2; exit 1; }
pct status "$CTID" >/dev/null 2>&1 || { echo "CT $CTID not found." >&2; exit 1; }

tmp="$(mktemp)"; trap 'rm -f "$tmp" "$tmp.2"' EXIT
pct pull "$CTID" "$ENVF" "$tmp" 2>/dev/null || : > "$tmp"   # start from the live .env, or empty

getval() { grep "^$1=" "$tmp" 2>/dev/null | tail -1 | cut -d= -f2-; }
upsert() { grep -v "^$1=" "$tmp" > "$tmp.2" 2>/dev/null || :; mv "$tmp.2" "$tmp"; printf '%s=%s\n' "$1" "$2"; printf '%s=%s\n' "$1" "$2" >> "$tmp"; } >/dev/null

echo "== maintainerr-keeper credentials =="
echo "Get these from https://discord.com/developers/applications → your app."
echo

# 1) Bot token (hidden input). Ask before replacing an existing one.
cur="$(getval DISCORD_BOT_TOKEN || true)"
ask_token=1
if [ -n "$cur" ]; then
  read -r -p "DISCORD_BOT_TOKEN already set. Replace it? [y/N] " a
  [[ "$a" =~ ^[Yy]$ ]] || ask_token=0
fi
if [ "$ask_token" = 1 ]; then
  read -rs -p "Paste the Bot token (Bot tab → Reset Token): " tok; echo
  [ -n "$tok" ] && upsert DISCORD_BOT_TOKEN "$tok" || echo "  (blank — left unchanged)"
fi

# 2) Channel id (visible). Ask before replacing.
cur="$(getval DISCORD_CHANNEL_ID || true)"
ask_ch=1
if [ -n "$cur" ]; then
  read -r -p "DISCORD_CHANNEL_ID is $cur. Replace it? [y/N] " a
  [[ "$a" =~ ^[Yy]$ ]] || ask_ch=0
fi
if [ "$ask_ch" = 1 ]; then
  read -r -p "Channel id (Developer Mode → right-click channel → Copy Channel ID): " ch
  [[ "$ch" =~ ^[0-9]+$ ]] && upsert DISCORD_CHANNEL_ID "$ch" || echo "  (not a number — left unchanged)"
fi

# 3) Dry-run — default ON the first time so a mis-click can't delete anything while you try it.
cur="$(getval DRY_RUN || true)"
if [ -z "$cur" ]; then
  read -r -p "Start in DRY-RUN (buttons just log, nothing excluded/deleted)? [Y/n] " a
  [[ "$a" =~ ^[Nn]$ ]] && upsert DRY_RUN 0 || upsert DRY_RUN 1
  echo "  DRY_RUN set — flip it to 0 in $ENVF (and restart the bot) once you've watched it work."
fi

pct push "$CTID" "$tmp" "$ENVF"
echo
echo "Saved to CT $CTID:$ENVF. Restarting the bot…"
pct exec "$CTID" -- bash -c 'cd /opt/media-pipeline && docker compose up -d --force-recreate maintainerr-keeper' \
  && echo "Done. Watch it: pct exec $CTID -- docker logs media-pipeline-maintainerr-keeper-1 --tail 20"
