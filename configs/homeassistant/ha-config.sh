#!/usr/bin/env bash
# ha-config.sh — view or tweak Home Assistant's config on VM 910 from the NUC-2 HOST,
# via the qemu guest agent (no add-on, no console needed). HAOS doesn't put its config
# in this repo (it's the one service that manages its own), so this reaches into the VM.
# If the guest agent's exec is disabled (HAOS can lock it down), it prints the manual
# console steps instead.
#   ./configs/homeassistant/ha-config.sh view            # show configuration.yaml
#   ./configs/homeassistant/ha-config.sh port 8123       # set http server_port + restart HA
#   ./configs/homeassistant/ha-config.sh restart         # restart HA core
set -uo pipefail
VMID=910
CONF='/config/configuration.yaml'            # path inside the homeassistant container

manual() {
  cat <<EOF

>> guest-exec isn't available on VM ${VMID} (HAOS has it disabled). Do it from the console:
   Proxmox UI -> VM ${VMID} -> Console, then at the 'ha >' prompt:
     login
     docker exec homeassistant cat ${CONF}
   To change the port:
     docker exec homeassistant sed -i -E 's/^([[:space:]]*server_port:).*/\1 8123/' ${CONF}
     ha core restart
EOF
}

# Run a shell command inside the VM via the agent. Prints the guest's stdout; returns the
# guest's exit code, or 2 if the agent couldn't exec at all (-> caller shows manual steps).
guest() {
  local raw
  raw="$(qm guest exec "$VMID" -- /bin/sh -c "$1" 2>&1)" || { printf '%s\n' "$raw" >&2; return 2; }
  printf '%s' "$raw" | python3 - <<'PY'
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    sys.stderr.write(raw); sys.exit(2)          # not JSON -> agent error
sys.stdout.write(d.get("out-data", "") or "")
if d.get("err-data"): sys.stderr.write(d["err-data"])
sys.exit(d.get("exitcode") or 0)
PY
}

case "${1:-view}" in
  view)
    echo "== VM ${VMID}: ${CONF} =="
    guest "docker exec homeassistant cat ${CONF}"; rc=$?
    [ "$rc" = 2 ] && { manual; exit 1; }; exit "$rc" ;;
  port)
    p="${2:?usage: $0 port <80|8123>}"
    echo "setting http server_port to ${p}..."
    guest "docker exec homeassistant sed -i -E 's/^([[:space:]]*server_port:).*/\\1 ${p}/' ${CONF}"
    rc=$?; [ "$rc" = 2 ] && { manual; exit 1; }
    echo "current http block now:"; guest "docker exec homeassistant sh -c 'grep -A3 \"^http:\" ${CONF} || echo \"(no http: block — port comes from a proxy add-on, not server_port)\"'"
    echo "restarting HA core (takes ~30s)..."; guest "ha core restart" >/dev/null 2>&1 || true
    echo "done — re-check with: ./configs/homeassistant/verify-ha.sh" ;;
  restart)
    guest "ha core restart" >/dev/null 2>&1; rc=$?
    [ "$rc" = 2 ] && { manual; exit 1; }; echo "HA core restarting." ;;
  *) echo "usage: $0 [view | port <80|8123> | restart]"; exit 1 ;;
esac
