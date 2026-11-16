#!/usr/bin/env bash
# common.sh — interactive helpers + a remembered values store, so you enter each
# value ONCE and every script prompts for whatever is still missing.
# Source it:  source "$(dirname "$0")/../lib/common.sh"   (adjust the path per script)
#
# Design: APIs run themselves, but every terminal command is shown and confirmed
# (run()), and anything destructive asks again (confirm()). Values persist in a
# gitignored per-box file; secrets go to their own gitignored files, never here.
set -euo pipefail

HL_ENV="${HL_ENV:-$HOME/.homelab.env}"     # per-box, gitignored, chmod 600
[ -f "$HL_ENV" ] && . "$HL_ENV"

# ---- colours (bright, so MANUAL steps / prompts stand out; respect NO_COLOR + non-TTY) ----
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RST=$'\033[0m'; C_MANUAL=$'\033[1;95m'; C_RUN=$'\033[1;96m'
  C_WARN=$'\033[1;93m'; C_OK=$'\033[1;92m'; C_HEAD=$'\033[1;97m'; C_SAVE=$'\033[30;103m'
else
  C_RST=; C_MANUAL=; C_RUN=; C_WARN=; C_OK=; C_HEAD=; C_SAVE=
fi
say()  { printf '%s==>%s %s\n' "$C_RUN" "$C_RST" "$*"; }
ok()   { printf '%s%s%s\n'    "$C_OK"   "$*" "$C_RST"; }
warn() { printf '%s%s%s\n'    "$C_WARN" "$*" "$C_RST"; }
hdr()  { printf '\n%s%s%s\n'  "$C_HEAD" "$*" "$C_RST"; }
# save(): highlight a value the user must write down / enter elsewhere
save() { printf '%s %s %s\n'  "$C_SAVE" "$*" "$C_RST"; }

_hl_save() { # _hl_save KEY VALUE
  touch "$HL_ENV"; chmod 600 "$HL_ENV"
  if grep -q "^export $1=" "$HL_ENV" 2>/dev/null; then
    sed -i "s|^export $1=.*|export $1=$(printf '%q' "$2")|" "$HL_ENV"
  else
    echo "export $1=$(printf '%q' "$2")" >> "$HL_ENV"
  fi
}

ask() { # ask KEY "Prompt" [default] — reuse stored value, else prompt + remember
  local key="$1" prompt="$2" def="${3:-}" cur="${!1:-}" ans
  if [ -n "$cur" ]; then printf -v "$key" '%s' "$cur"; return; fi
  read -rp "$C_WARN$prompt${def:+ [$def]}:$C_RST " ans
  ans="${ans:-$def}"
  [ -z "$ans" ] && { echo "  (required)"; ask "$@"; return; }
  printf -v "$key" '%s' "$ans"; _hl_save "$key" "$ans"
}

ask_secret() { # ask_secret "Prompt" FILE — hidden input, written to a gitignored file
  local prompt="$1" file="$2" s
  if [ -s "$file" ]; then echo "  $file already set — skipping."; return; fi
  mkdir -p "$(dirname "$file")"
  read -rsp "$C_WARN$prompt:$C_RST " s; echo
  [ -z "$s" ] && { echo "  (skipped)"; return; }
  printf '%s' "$s" > "$file"; chmod 600 "$file"
  echo "  wrote $file (gitignored — also save it to your vault, R21)."
}

envset() { # envset FILE KEY "Prompt" [--secret] — upsert KEY=value into an env file
  local file="$1" key="$2" prompt="$3" secret="${4:-}" v
  mkdir -p "$(dirname "$file")"; touch "$file"; chmod 600 "$file"
  if [ "$secret" = "--secret" ]; then read -rsp "$C_WARN$prompt:$C_RST " v; echo; else read -rp "$C_WARN$prompt:$C_RST " v; fi
  [ -z "$v" ] && { echo "  (skipped $key)"; return; }
  if grep -q "^$key=" "$file"; then sed -i "s|^$key=.*|$key=$v|" "$file"; else echo "$key=$v" >> "$file"; fi
  echo "  set $key in $file"
}

confirm() { local a; read -rp "$C_WARN$1 [y/N]:$C_RST " a; [[ "$a" == [yY]* ]]; }

pick_disk() { # pick_disk KEY "Prompt" — show disks, validate, confirm by identity
  echo; lsblk -o NAME,SIZE,TYPE,MODEL,SERIAL; echo
  local dev; read -rp "$C_WARN$2 (e.g. /dev/sdb):$C_RST " dev
  [ -b "$dev" ] || { warn "  !! $dev is not a block device."; pick_disk "$1" "$2"; return; }
  echo "  $dev -> $(lsblk -dno MODEL,SIZE "$dev" 2>/dev/null)"
  confirm "  Use $dev?" || { pick_disk "$1" "$2"; return; }
  printf -v "$1" '%s' "$dev"; _hl_save "$1" "$dev"
}

pick_by_id() { # pick_by_id KEY "Prompt" — stable /dev/disk/by-id path
  echo; ls -l /dev/disk/by-id/ | grep -v -- '-part'; echo
  local p; read -rp "$C_WARN$2 (/dev/disk/by-id/...):$C_RST " p
  [ -b "$p" ] || { warn "  !! not a block device."; pick_by_id "$1" "$2"; return; }
  printf -v "$1" '%s' "$p"; _hl_save "$1" "$p"
}

run() { # run CMD ... — show it, confirm, then run (terminal commands stay gated)
  printf '\n%s+ %s%s\n' "$C_RUN" "$*" "$C_RST"
  confirm "  Run this?" || { echo "  skipped."; return 0; }
  "$@"
}

pause() { printf '\n%s>> MANUAL: %s%s\n' "$C_MANUAL" "$1" "$C_RST"; read -rp "   Press Enter when done... " _; }

need_root() { [ "$(id -u)" = 0 ] || { warn "Run as root (sudo)."; exit 1; }; }
