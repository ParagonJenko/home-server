#!/usr/bin/env bash
# ha-config.sh — manage Home Assistant (VM 910) from the NUC-2 host, in one place.
# HAOS keeps its config inside the VM and blocks the qemu agent's exec, so this runs the
# commands over SSH into HAOS. Run `setup-ssh` once; after that each command does the whole
# job (edit + restart + verify) so you're not stringing steps together.
#   ./configs/homeassistant/ha-config.sh setup-ssh     # one-time: make + authorise an SSH key
#   ./configs/homeassistant/ha-config.sh status        # (default) IP, http block, + full verify
#   ./configs/homeassistant/ha-config.sh view          # the whole configuration.yaml
#   ./configs/homeassistant/ha-config.sh port 8123     # set http port -> restart -> verify, in one
#   ./configs/homeassistant/ha-config.sh restart       # restart HA core, then verify
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VMID=910
CONF='/config/configuration.yaml'                 # path inside the homeassistant container
HA_SSH_HOST="${HA_SSH_HOST:-192.168.1.25}"
HA_SSH_PORT="${HA_SSH_PORT:-22222}"               # HAOS OS SSH; set HA_SSH_PORT=22 for the add-on
HA_SSH_USER="${HA_SSH_USER:-root}"
KEY="${HA_SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS=(-p "$HA_SSH_PORT" -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)

ssh_reachable() { ssh "${SSH_OPTS[@]}" "${HA_SSH_USER}@${HA_SSH_HOST}" true 2>/dev/null; }
run_ha()        { ssh "${SSH_OPTS[@]}" "${HA_SSH_USER}@${HA_SSH_HOST}" "$1"; }

need_ssh() {
  ssh_reachable && return 0
  cat <<EOF
>> Can't SSH to HAOS at ${HA_SSH_USER}@${HA_SSH_HOST}:${HA_SSH_PORT}.
   - SSH add-on? In its Configuration set 'username: root' AND 'authorized_keys', turn OFF
     Protection mode, expose port 22, Start it — then run with HA_SSH_PORT=22
     (and HA_SSH_USER=<name> if you set a username other than root).
   - Not set up yet?  ./configs/homeassistant/ha-config.sh setup-ssh
   - Or from the Proxmox console: VM ${VMID} -> Console -> 'login', then
     docker exec homeassistant cat ${CONF}
EOF
  return 1
}

restart_and_verify() {
  echo "restarting HA core (~30s)..."; run_ha "ha core restart" >/dev/null 2>&1 || true
  sleep 8
  "$HERE/verify-ha.sh"
}

case "${1:-status}" in
  setup-ssh)
    [ -f "$KEY" ] || { echo "making an SSH key at ${KEY}"; ssh-keygen -t ed25519 -f "$KEY" -N '' -q; }
    echo "== one-time HAOS SSH setup =="
    echo "nuc2's public key:"; echo; cat "${KEY}.pub"; echo
    cat <<EOF
Authorise it on HAOS (pick one), then re-run any command:
 A) HAOS OS SSH on :22222 (no add-on) — Proxmox UI -> VM ${VMID} -> Console -> type 'login', then:
      mkdir -p /root/.ssh && chmod 700 /root/.ssh
      echo '$(cat "${KEY}.pub")' >> /root/.ssh/authorized_keys
    This console step is the only manual bit; everything after runs from here.
 B) 'Advanced SSH & Web Terminal' add-on (HA UI -> Settings -> Add-ons). Easier to paste into:
    1. Configuration tab: set  username: root  AND add the key under  authorized_keys:  . Save.
       (it logs in as that username — if you leave it unset/other, SSH as root is refused)
    2. Info tab: turn OFF 'Protection mode' (so docker/ha commands are allowed).
    3. Network: expose SSH on port 22. Then Start the add-on (it won't start without a key).
    4. Run with the add-on's port:  HA_SSH_PORT=22 ./configs/homeassistant/ha-config.sh status
       (add HA_SSH_USER=<name> if you used a username other than root)
Then:  ./configs/homeassistant/ha-config.sh status   (or 'HA_SSH_PORT=22 ...' for the add-on)
EOF
    ;;
  status)
    need_ssh || exit 1
    echo "== HA http config (VM ${VMID}) =="
    run_ha "docker exec homeassistant sh -c 'grep -A4 \"^http:\" ${CONF} || echo \"(no http: block -> default port 8123, or a proxy add-on sets the port)\"'"
    echo
    "$HERE/verify-ha.sh" ;;
  view)
    need_ssh || exit 1
    echo "== VM ${VMID}: ${CONF} =="
    run_ha "docker exec homeassistant cat ${CONF}" ;;
  port)
    p="${2:?usage: $0 port <80|8123>}"; need_ssh || exit 1
    echo "setting http server_port to ${p}..."
    run_ha "docker exec homeassistant sed -i -E 's/^([[:space:]]*server_port:).*/\\1 ${p}/' ${CONF}"
    echo "http block now:"
    run_ha "docker exec homeassistant sh -c 'grep -A4 \"^http:\" ${CONF}'"
    restart_and_verify ;;
  restart)
    need_ssh || exit 1
    restart_and_verify ;;
  *) echo "usage: $0 [setup-ssh | status | view | port <80|8123> | restart]"; exit 1 ;;
esac
