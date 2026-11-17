#!/usr/bin/env bash
# offsite-setup.sh — RUN ON THE PBS VM. One-time: turn your Backblaze B2 creds into an rclone
# remote for the offsite sync, test it, and record it for offsite-sync.sh. No interactive
# `rclone config` wizard — it prompts for the few values and writes the remote itself.
#
# Your PBS backups are ALREADY client-side encrypted (G5 datastore key), so a plain B2 remote
# stores ciphertext. The optional rclone crypt layer additionally hides filenames + structure,
# at the cost of one more key you must keep (lose it = offsite copy unrecoverable). [R21]
set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"
need_root
CRYPT_PW=""

command -v rclone >/dev/null || { say "installing rclone"; apt-get update -qq && apt-get install -y rclone; }

hdr "Backblaze B2 details"
echo "From the B2 console you need: a private bucket, and an Application Key scoped to it."
ask B2_BUCKET "B2 bucket name"
ask B2_KEY_ID "B2 keyID (the application key's ID)"
read -rsp "${C_WARN}B2 applicationKey (hidden):${C_RST} " B2_APP_KEY; echo
[ -n "$B2_APP_KEY" ] || { warn "no applicationKey — aborting."; exit 1; }
B2_PATH="${B2_PATH:-pbs}"

say "create rclone b2 remote 'b2backup'"
rclone config create b2backup b2 account "$B2_KEY_ID" key "$B2_APP_KEY" >/dev/null

hdr "test connectivity to B2"
if rclone lsf "b2backup:${B2_BUCKET}" >/dev/null 2>&1; then
  ok "reached bucket '${B2_BUCKET}' (empty listing is fine on first run)."
else
  warn "couldn't reach 'b2backup:${B2_BUCKET}' — check the key is scoped to that bucket and the name is exact."
  confirm "Carry on anyway?" || exit 1
fi

REMOTE="b2backup:${B2_BUCKET}/${B2_PATH}"
if confirm "Add an rclone crypt layer on top? (hides filenames/structure — but it's ONE MORE key to vault)"; then
  read -rsp "${C_WARN}crypt password (hidden — SAVE to vault; lose it = offsite copy unrecoverable):${C_RST} " CRYPT_PW; echo
  if [ -n "$CRYPT_PW" ]; then
    rclone config create cryptbackup crypt remote "$REMOTE" password "$(rclone obscure "$CRYPT_PW")" >/dev/null
    REMOTE="cryptbackup:"
    ok "crypt remote created over b2backup."
  else
    warn "no password entered — keeping the plain B2 remote (already encrypted by PBS)."
  fi
fi

_hl_save OFFSITE_REMOTE "$REMOTE"
ok "saved OFFSITE_REMOTE=${REMOTE} to ${HL_ENV} — offsite-sync.sh picks it up automatically."
save "Back up ~/.config/rclone/rclone.conf to your vault (R21) — it holds the B2 key${CRYPT_PW:+ and the crypt password}."
echo
echo "Next:  ./configs/pbs/offsite-sync.sh --run          # one real sync"
echo "       ./configs/pbs/offsite-sync.sh --install-timer # daily 05:00"
