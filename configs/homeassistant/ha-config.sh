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
HA_SSH_USER="${HA_SSH_USER:-root}"
KEY="${HA_SSH_KEY:-$HOME/.ssh/id_ed25519}"
# Ports to try, in order: an explicit HA_SSH_PORT wins; else HAOS OS SSH :22222 then add-on :22.
PORTS=("${HA_SSH_PORT:-22222}" 22)
PORT=""

_ssh() { ssh -p "$1" -i "$KEY" -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new "${HA_SSH_USER}@${HA_SSH_HOST}" "${@:2}"; }
pick_port() {   # find the first SSH port that answers; cache it in PORT
  [ -n "$PORT" ] && return 0
  local p
  for p in "${PORTS[@]}"; do _ssh "$p" true 2>/dev/null && { PORT="$p"; return 0; }; done
  return 1
}
ssh_reachable() { pick_port; }
run_ha()        { pick_port || return 1; _ssh "$PORT" "$1"; }

need_ssh() {
  ssh_reachable && return 0
  cat <<EOF
>> Can't SSH to HAOS at ${HA_SSH_USER}@${HA_SSH_HOST} (tried ports ${PORTS[*]}).
   - SSH add-on? In its Configuration set 'username: root' AND 'authorized_keys', turn OFF
     Protection mode, expose port 22, Start it (this script auto-finds :22).
     If you used a username other than root, run with HA_SSH_USER=<name>.
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
    4. Start the add-on, then:  ./configs/homeassistant/ha-config.sh status
       (the script auto-tries :22222 then :22; add HA_SSH_USER=<name> if not root)
Then:  ./configs/homeassistant/ha-config.sh status
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
  enable-prometheus)
    need_ssh || exit 1
    if run_ha "docker exec homeassistant grep -q '^prometheus:' ${CONF}"; then
      echo "prometheus: already present in ${CONF} — nothing to add."
    else
      echo "appending the prometheus: block to ${CONF}..."
      run_ha "docker exec -i homeassistant sh -c 'cat >> ${CONF}'" <<'YAML'

# --- added by ha-config.sh enable-prometheus: exposes /api/prometheus for the homelab Prometheus ---
prometheus:
  namespace: homeassistant
  filter:
    include_domains:
      - light
      - sensor
      - binary_sensor
      - switch
      - climate
      - device_tracker
YAML
    fi
    echo "validating HA config..."
    if ! run_ha "ha core check"; then
      echo "!! 'ha core check' failed — fix configuration.yaml before restarting. Not restarting." >&2
      exit 1
    fi
    restart_and_verify
    echo
    echo ">> Integration enabled. Two manual bits remain (a token can't be minted safely in code):"
    echo "   1. HA -> your profile -> Security -> Long-lived access tokens -> Create. Copy it."
    echo "   2. On the Pi: add HA_TOKEN=<token> to /opt/pi-stack/.env (or run gather-exporter-creds.sh),"
    echo "      then ./configs/pi/redeploy.sh"
    ;;
  *) echo "usage: $0 [setup-ssh | status | view | port <80|8123> | restart | enable-prometheus]"; exit 1 ;;
esac
