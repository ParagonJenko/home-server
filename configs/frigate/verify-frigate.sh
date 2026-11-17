#!/usr/bin/env bash
# verify-frigate.sh — health check for Frigate. Runs on the NUC-2 HOST (so it can see
# the LVM thin pool), and reaches into CT 111 for the container checks. Read-only.
#   ./configs/frigate/verify-frigate.sh
# Safe to run BEFORE frigate.sh too — the host/pool checks still apply; it just notes
# the container isn't built yet.
set -uo pipefail
CTID=111
CAMS="cam-living-room cam-kitchen cam-bedroom cam-basement"
G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; Z=$'\e[0m'
fails=0
pass(){ echo "${G}PASS${Z} $*"; }
fail(){ echo "${R}FAIL${Z} $*"; fails=$((fails+1)); }
warn(){ echo "${Y}WARN${Z} $*"; }

echo "== host: local-lvm thin pool (R6/R8/R9) =="
if command -v lvs >/dev/null 2>&1; then
  line="$(lvs --noheadings --units g -o lv_name,lv_size,data_percent,metadata_percent pve/data 2>/dev/null)"
  if [ -n "$line" ]; then
    psize="$(echo "$line" | awk '{gsub(/[gG]/,"",$2); print int($2)}')"
    dpct="$(echo "$line"  | awk '{print $3}')"
    mpct="$(echo "$line"  | awk '{print $4}')"
    pass "thin pool pve/data = ${psize}G (data ${dpct}% / meta ${mpct}%)"
    if [ "${psize:-0}" -ge 308 ]; then pass "  >= 308G — fits Frigate 260 + PBS 16 + HA 32"; else warn "  only ${psize}G — 260+16+32=308G may not fit; recheck B5 sizing"; fi
    if awk "BEGIN{exit !(${dpct:-0} < 85)}" 2>/dev/null; then pass "  data ${dpct}% used — healthy"; else warn "  data ${dpct}% used — thin pool nearing full (R8; autoextend should be on)"; fi
    if awk "BEGIN{exit !(${mpct:-0} < 85)}" 2>/dev/null; then pass "  metadata ${mpct}% used — healthy"; else warn "  metadata ${mpct}% used — metadata exhaustion is the corruption path (R8)"; fi
  else
    warn "couldn't read the pve/data thin pool from lvs"
  fi
else
  warn "lvs not found — run this on the NUC-2 Proxmox host, not inside a container"
fi

echo "== container ${CTID} =="
if ! pct status "$CTID" >/dev/null 2>&1; then
  warn "CT ${CTID} doesn't exist yet — host/pool checked above; run again after frigate.sh for the full check."
  echo; [ "$fails" = 0 ] && exit 0 || exit 1
fi
if pct status "$CTID" 2>/dev/null | grep -q running; then
  pass "CT ${CTID} running"
else
  fail "CT ${CTID} exists but isn't running"; echo; echo "${R}start it first, then re-run.${Z}"; exit 1
fi

# ---- in-container Frigate checks (piped into CT 111) ----
pct exec "$CTID" -- bash -s <<'INNER'
set -uo pipefail
cd /opt/frigate
CAMS="cam-living-room cam-kitchen cam-bedroom cam-basement"
G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; Z=$'\e[0m'
f=0
pass(){ echo "${G}PASS${Z} $*"; }
fail(){ echo "${R}FAIL${Z} $*"; f=$((f+1)); }
warn(){ echo "${Y}WARN${Z} $*"; }

echo "== frigate service =="
st="$(docker compose ps frigate --format '{{.State}}' 2>/dev/null | head -1)"
[ "$st" = running ] && pass "frigate container running" || { fail "frigate not running (${st:-none})"; exit 1; }

echo "== web UI (:8971, authenticated) =="
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:8971/ 2>/dev/null)"
case "$code" in 200|302|401) pass "auth UI answers on :8971 (HTTP ${code})";; *) fail "auth UI :8971 returned ${code:-none}";; esac

echo "== :5000 must NOT be exposed (R13) =="
if curl -s -o /dev/null --max-time 5 http://localhost:5000/ 2>/dev/null; then
  fail ":5000 answered on the LXC host — it must NOT be published (unauthenticated)"
else
  pass ":5000 not exposed on the LXC host"
fi

echo "== config + live camera state =="
out="$(docker compose exec -T frigate python3 - "$CAMS" <<'PY' 2>/dev/null
import urllib.request, json, sys
cams = sys.argv[1].split()
def get(p): return json.load(urllib.request.urlopen("http://127.0.0.1:5000"+p, timeout=10))
try:
    cfg = get("/api/config"); stats = get("/api/stats")
except Exception:
    print("APIERR"); sys.exit(0)
cfgcams = set((cfg.get("cameras") or {}).keys())
for c in cams:
    s = stats.get(c) if isinstance(stats.get(c), dict) else {}
    fps = s.get("camera_fps", 0) or 0
    print(f"CAM {c} {'yes' if c in cfgcams else 'no'} {fps}")
PY
)"
if [ -z "$out" ] || echo "$out" | grep -q APIERR; then
  fail "Frigate API not answering yet (api/config + api/stats) — still starting?"
else
  while read -r _ cam incfg fps; do
    [ -z "${cam:-}" ] && continue
    if [ "$incfg" = yes ]; then pass "  $cam in loaded config"; else fail "  $cam MISSING from loaded config (stale config.yaml?)"; fi
    if awk "BEGIN{exit !($fps > 0)}" 2>/dev/null; then pass "  $cam streaming (${fps} fps)"; else warn "  $cam no stream (RTSP down / camera offline / not set up yet)"; fi
  done <<< "$out"
fi

echo "== hardware decode (/dev/dri) =="
if docker compose exec -T frigate sh -c 'ls /dev/dri/renderD128 >/dev/null 2>&1'; then
  pass "/dev/dri/renderD128 present in the container (iGPU decode)"
else
  warn "no /dev/dri/renderD128 — CPU decode (fine if this NUC has no usable iGPU)"
fi

echo "== recordings =="
if docker compose exec -T frigate sh -c 'test -w /media/frigate' 2>/dev/null; then
  pass "/media/frigate is writable"
else
  fail "/media/frigate not writable — recordings will fail"
fi

exit "$f"
INNER
fails=$((fails + $?))

echo
if [ "$fails" = 0 ]; then
  echo "${G}ALL CHECKS PASSED — pool healthy, Frigate up, :5000 not exposed, GPU + recordings OK.${Z}"
  echo "(Camera WARNs just mean those streams aren't live yet — fine until the cameras are set up.)"; exit 0
else
  echo "${R}${fails} check(s) failed${Z} — inspect the failing item above."; exit 1
fi
