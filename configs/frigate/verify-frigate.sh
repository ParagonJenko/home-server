#!/usr/bin/env bash
# verify-frigate.sh — read-only health check for Frigate (LXC 111). Runs INSIDE the
# LXC. Green PASS / red FAIL / yellow WARN per check; changes nothing.
#   pct exec 111 -- bash /opt/frigate/verify-frigate.sh
set -uo pipefail
cd /opt/frigate
CAMS="cam-living-room cam-kitchen cam-bedroom cam-basement"
G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; Z=$'\e[0m'
fails=0
pass(){ echo "${G}PASS${Z} $*"; }
fail(){ echo "${R}FAIL${Z} $*"; fails=$((fails+1)); }
warn(){ echo "${Y}WARN${Z} $*"; }

echo "== container =="
st="$(docker compose ps frigate --format '{{.State}}' 2>/dev/null | head -1)"
if [ "$st" = running ]; then pass "frigate running"; else
  fail "frigate not running (state: ${st:-none})"; echo; echo "${R}frigate isn't up — fix that first.${Z}"; exit 1
fi

echo "== web UI (:8971, authenticated) =="
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:8971/ 2>/dev/null)"
case "$code" in 200|302|401) pass "auth UI answers on :8971 (HTTP ${code})";; *) fail "auth UI :8971 returned ${code:-none}";; esac

echo "== :5000 must NOT be exposed (R13) =="
# 5000 is the UNAUTHENTICATED API — only reachable inside the container, never published.
if curl -s -o /dev/null --max-time 5 http://localhost:5000/ 2>/dev/null; then
  fail ":5000 answered on the LXC host — it must NOT be published (it's unauthenticated)"
else
  pass ":5000 not exposed on the LXC host"
fi

echo "== config + live camera state =="
# Talk to the internal API through the container's own python (5000 isn't published).
out="$(docker compose exec -T frigate python3 - "$CAMS" <<'PY' 2>/dev/null
import urllib.request, json, sys
cams = sys.argv[1].split()
def get(p): return json.load(urllib.request.urlopen("http://127.0.0.1:5000"+p, timeout=10))
try:
    cfg = get("/api/config"); stats = get("/api/stats")
except Exception as e:
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
    if [ "$incfg" = yes ]; then pass "  $cam in config"; else fail "  $cam MISSING from loaded config (stale config.yaml?)"; fi
    # camera_fps > 0 means the stream is connecting; 0 means RTSP down / camera offline
    if awk "BEGIN{exit !($fps > 0)}" 2>/dev/null; then pass "  $cam streaming (${fps} fps)"; else warn "  $cam no stream (RTSP down / camera offline / not set up yet)"; fi
  done <<< "$out"
fi

echo "== hardware decode (/dev/dri) =="
if docker compose exec -T frigate sh -c 'ls /dev/dri/renderD128 >/dev/null 2>&1'; then
  pass "/dev/dri/renderD128 present in the container (iGPU decode)"
else
  warn "no /dev/dri/renderD128 in the container — running CPU decode (fine if this NUC has no usable iGPU)"
fi

echo "== recordings =="
if docker compose exec -T frigate sh -c 'test -w /media/frigate' 2>/dev/null; then
  pass "/media/frigate is writable"
else
  fail "/media/frigate not writable — recordings will fail"
fi
use="$(df -P /opt/frigate/media 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"
if [ -n "${use:-}" ]; then
  if [ "$use" -lt 90 ]; then pass "recordings disk ${use}% used (cap is the 260G rootfs, R6)"; else warn "recordings disk ${use}% used — nearing the cap; Frigate prunes oldest (R7)"; fi
fi

echo
if [ "$fails" = 0 ]; then
  echo "${G}ALL CHECKS PASSED — Frigate up, config loaded, :5000 not exposed, GPU + recordings OK.${Z}"
  echo "(WARNs for cameras just mean those streams aren't live yet — fine until the cameras are set up.)"; exit 0
else
  echo "${R}${fails} check(s) failed${Z} — inspect the failing item above."; exit 1
fi
