#!/usr/bin/env bash
# pbs-finalize.sh — finish the PBS VM (900) after its interactive install, from the NUC-2 host.
# The two things the PBS OS installer can't do itself, both scripted here:
#   1. stop the VM re-entering the installer — switch boot off the ISO + detach it   [host-side]
#   2. turn the passed-through 2TB disk into the 'backups' datastore + retention      [over SSH]
# PBS has no qemu-agent exec channel we rely on, so step 2 runs over SSH (like ha-config.sh).
# Run `setup-ssh` once to authorise a key into PBS, then `finalize`.
#   ./configs/pbs/pbs-finalize.sh setup-ssh    # one-time: authorise an SSH key into PBS
#   ./configs/pbs/pbs-finalize.sh finalize      # (default) boot-switch + datastore, end to end
#   ./configs/pbs/pbs-finalize.sh boot-switch   # just the boot-order fix
#   ./configs/pbs/pbs-finalize.sh datastore     # just the datastore (disk + retention)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VMID=900
PBS_HOST="${PBS_SSH_HOST:-192.168.1.5}"        # PBS static IP (R13 — PBS writes its own address)
PBS_USER="${PBS_SSH_USER:-root}"
KEY="${PBS_SSH_KEY:-$HOME/.ssh/id_ed25519}"
DATASTORE=backups
DATASTORE_PATH="/mnt/datastore/${DATASTORE}"   # where 'disk fs create' mounts it inside the VM

G=$'\e[1;92m'; R=$'\e[1;91m'; Y=$'\e[1;93m'; H=$'\e[1;97m'; Z=$'\e[0m'
ok()   { echo "${G}$*${Z}"; }
warn() { echo "${Y}$*${Z}"; }
err()  { echo "${R}$*${Z}"; }
hdr()  { echo; echo "${H}== $* ==${Z}"; }
confirm() { local a; read -rp "${Y}$1 [y/N]:${Z} " a; [[ "$a" == [yY]* ]]; }

_ssh()  { ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new "${PBS_USER}@${PBS_HOST}" "$@"; }
ssh_ok(){ _ssh true 2>/dev/null; }

need_vm() { qm status "$VMID" >/dev/null 2>&1 || { err "VM ${VMID} doesn't exist — run pbs-vm.sh first."; exit 1; }; }
need_ssh(){ ssh_ok || { err "Can't SSH to ${PBS_USER}@${PBS_HOST} — run: $0 setup-ssh"; return 1; }; }

# -- 1. boot order (host-side) ------------------------------------------------
boot_switch() {
  need_vm
  # Guard: never eject the ISO unless PBS is actually installed and answering. Otherwise we'd
  # point boot at a blank disk and the VM lands in "unknown filesystem" at the next reboot.
  if ! curl -sk -o /dev/null --max-time 5 "https://${PBS_HOST}:8007/" 2>/dev/null; then
    err "PBS isn't answering on ${PBS_HOST}:8007 — the install hasn't finished."
    warn "Run the PBS installer in the VM console first (target the 16G disk), then re-run this."
    warn "Ejecting the ISO now would leave the VM booting a blank disk ('unknown filesystem')."
    return 1
  fi
  hdr "boot order: switch off the installer ISO"
  local boot; boot="$(qm config "$VMID" 2>/dev/null | awk -F': ' '/^boot:/{print $2}')"
  if echo "$boot" | grep -q ide2; then
    qm set "$VMID" --boot order=scsi0
    qm set "$VMID" --ide2 none
    ok "boot now from scsi0; installer ISO detached — reboots go straight into PBS."
  else
    ok "already booting from the system disk (boot: ${boot:-unset}) — nothing to do."
  fi
}

# -- 2. datastore (over SSH, inside the PBS VM) -------------------------------
datastore() {
  need_ssh || return 1

  # Already set up? (disk mounted + datastore defined) -> skip the destructive bit.
  if _ssh "proxmox-backup-manager datastore list 2>/dev/null | grep -qw ${DATASTORE}"; then
    ok "datastore '${DATASTORE}' already exists on PBS — skipping disk init, re-applying retention."
  else
    hdr "datastore disk (inside PBS VM ${VMID})"
    # Candidate = a whole disk with nothing mounted anywhere in its tree (not the root disk,
    # not an already-mounted datastore). The fresh 2TB passthrough is the one with no mounts.
    local lines; lines="$(_ssh bash -s <<'REMOTE'
for d in $(lsblk -dn -e 1,7 -o NAME 2>/dev/null); do
  dev="/dev/$d"
  lsblk -no MOUNTPOINT "$dev" 2>/dev/null | grep -q . && continue   # skip if anything under it is mounted
  printf '%s|%s|%s\n' "$d" "$(lsblk -dno SIZE "$dev" 2>/dev/null)" "$(lsblk -dno MODEL "$dev" 2>/dev/null)"
done
REMOTE
)"
    mapfile -t cands < <(printf '%s\n' "$lines" | sed '/^$/d')
    if [ "${#cands[@]}" -eq 0 ]; then
      err "No free disk inside the VM. Is the 2TB attached as scsi1? Check: qm config ${VMID} | grep scsi1"
      return 1
    fi
    local disk
    if [ "${#cands[@]}" -eq 1 ]; then
      IFS='|' read -r disk sz model <<< "${cands[0]}"
      echo "  found: /dev/${disk}  (${sz}  ${model})"
    else
      echo "  more than one unmounted disk — pick the 2TB datastore disk:"
      local i; for i in "${!cands[@]}"; do IFS='|' read -r d sz model <<< "${cands[$i]}"; printf "   %2d) /dev/%s  (%s  %s)\n" "$((i+1))" "$d" "$sz" "$model"; done
      local n; read -rp "${Y}  number:${Z} " n
      [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#cands[@]}" ] || { err "  not a valid choice."; return 1; }
      IFS='|' read -r disk sz model <<< "${cands[$((n-1))]}"
    fi
    warn "  This FORMATS /dev/${disk} (ext4) and mounts it at ${DATASTORE_PATH}. All data on it is lost."
    confirm "  Format /dev/${disk} and create the '${DATASTORE}' datastore?" || { echo "  skipped."; return 1; }
    _ssh "proxmox-backup-manager disk fs create ${DATASTORE} --disk ${disk} --filesystem ext4 --add-datastore true" \
      || { err "  disk fs create failed — check the PBS console."; return 1; }
    ok "  /dev/${disk} formatted, mounted at ${DATASTORE_PATH}, datastore '${DATASTORE}' created."
  fi

  # Retention / GC / prune — push the repo's datastore-setup.sh (path filled in) and run it.
  hdr "retention + GC + prune (datastore-setup.sh)"
  local tmp; tmp="$(mktemp)"
  sed "s#<DATASTORE_PATH>#${DATASTORE_PATH}#" "$HERE/datastore-setup.sh" > "$tmp"
  scp -q -i "$KEY" -o StrictHostKeyChecking=accept-new "$tmp" "${PBS_USER}@${PBS_HOST}:/root/datastore-setup.sh"
  rm -f "$tmp"
  _ssh "bash /root/datastore-setup.sh"
  echo
  ok "datastore ready. Next: point the NUCs' backups at PBS (G5), then verify (./configs/pbs/verify-pbs.sh)."
}

case "${1:-finalize}" in
  setup-ssh)
    [ -f "$KEY" ] || { echo "making an SSH key at ${KEY}"; ssh-keygen -t ed25519 -f "$KEY" -N '' -q; }
    if ssh_ok; then ok "key already works — SSH to ${PBS_USER}@${PBS_HOST} is set up. Run: $0 finalize"; exit 0; fi
    hdr "one-time PBS SSH setup"
    if command -v ssh-copy-id >/dev/null 2>&1; then
      echo "Copying nuc2's key to PBS. Enter the PBS root password you set during install when asked:"
      ssh-copy-id -i "${KEY}.pub" -o StrictHostKeyChecking=accept-new "${PBS_USER}@${PBS_HOST}" || true
    fi
    if ssh_ok; then ok "key authorised. Run: $0 finalize"; exit 0; fi
    cat <<EOF
Couldn't copy the key automatically. Authorise it by hand (one console step):
  Proxmox UI -> VM ${VMID} -> Console -> log in as root, then:
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    echo '$(cat "${KEY}.pub")' >> /root/.ssh/authorized_keys
Then re-run: $0 finalize
EOF
    ;;
  boot-switch) boot_switch ;;
  datastore)   datastore ;;
  finalize)    boot_switch && datastore ;;
  *) echo "usage: $0 [setup-ssh | finalize | boot-switch | datastore]"; exit 1 ;;
esac
