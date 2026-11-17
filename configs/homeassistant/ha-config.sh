#!/usr/bin/env bash
# ha-config.sh — view/change HA's configuration.yaml on VM 910 FROM the NUC-2 host.
# HAOS keeps its config inside the VM (the one service not managed in this repo) and
# blocks the qemu agent's exec, so this runs the commands over SSH into HAOS. First time,
# run `setup-ssh` once to enable the channel; after that view/port/restart just work.
#   ./configs/homeassistant/ha-config.sh setup-ssh       # one-time: enable + authorise SSH
#   ./configs/homeassistant/ha-config.sh view            # show configuration.yaml
#   ./configs/homeassistant/ha-config.sh port 8123       # set http server_port + restart
#   ./configs/homeassistant/ha-config.sh restart         # restart HA core
set -uo pipefail
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
  if ssh_reachable; then return 0; fi
  cat <<EOF
>> Can't SSH to HAOS at ${HA_SSH_USER}@${HA_SSH_HOST}:${HA_SSH_PORT}.
   Run once:  ./configs/homeassistant/ha-config.sh setup-ssh
   (or do it from the Proxmox console: VM ${VMID} -> Console -> 'login', then
    docker exec homeassistant cat ${CONF})
EOF
  return 1
}

case "${1:-view}" in
  setup-ssh)
    [ -f "$KEY" ] || { echo "making an SSH key at ${KEY}"; ssh-keygen -t ed25519 -f "$KEY" -N '' -q; }
    echo "== one-time HAOS SSH setup =="
    echo "nuc2's public key:"; echo; cat "${KEY}.pub"; echo
    cat <<EOF
Authorise it on HAOS (pick one), then re-run 'view':
 A) HAOS OS SSH on :22222 (no add-on) — Proxmox UI -> VM ${VMID} -> Console -> type 'login', then:
      mkdir -p /root/.ssh && chmod 700 /root/.ssh
      echo '$(cat "${KEY}.pub")' >> /root/.ssh/authorized_keys
    This console step is the only manual bit; everything after runs from here.
 B) 'Advanced SSH & Web Terminal' add-on (HA UI -> Settings -> Add-ons -> Store): paste the key
    above into its 'authorized_keys' option, start it, then run this script with HA_SSH_PORT=22.
Test:  ./configs/homeassistant/ha-config.sh view
EOF
    ;;
  view)
    need_ssh || exit 1
    echo "== VM ${VMID}: ${CONF} =="
    run_ha "docker exec homeassistant cat ${CONF}" ;;
  port)
    p="${2:?usage: $0 port <80|8123>}"; need_ssh || exit 1
    echo "setting http server_port to ${p}..."
    run_ha "docker exec homeassistant sed -i -E 's/^([[:space:]]*server_port:).*/\\1 ${p}/' ${CONF}"
    echo "http block now:"
    run_ha "docker exec homeassistant sh -c 'grep -A3 \"^http:\" ${CONF} || echo \"(no http: block — port 80 comes from a proxy add-on, not server_port)\"'"
    echo "restarting HA core (~30s)..."; run_ha "ha core restart" >/dev/null 2>&1 || true
    echo "done — re-check: ./configs/homeassistant/verify-ha.sh" ;;
  restart)
    need_ssh || exit 1
    run_ha "ha core restart" >/dev/null 2>&1 && echo "HA core restarting." ;;
  *) echo "usage: $0 [setup-ssh | view | port <80|8123> | restart]"; exit 1 ;;
esac
