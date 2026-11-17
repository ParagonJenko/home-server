#!/usr/bin/env bash
# verify-backups.sh — check this host's PBS backups (R4). Run on EACH NUC host.
# Confirms the PBS storage is active and that every local guest is covered by a backup
# job — except the two deliberate exclusions:
#   - Frigate (CT 111): 260G of churning recordings would overrun the datastore; its
#     config rebuilds from the repo (R7), so it's left out.
#   - the PBS VM (900) itself: can't back a PBS up to its own datastore (circular); its
#     config is kept offsite instead (G6).
#   ./configs/pbs/verify-backups.sh
set -uo pipefail
EXCLUDED="111 900"            # frigate recordings + the PBS VM — deliberately not backed up
G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; Z=$'\e[0m'
fails=0
pass(){ echo "${G}PASS${Z} $*"; }
fail(){ echo "${R}FAIL${Z} $*"; fails=$((fails+1)); }
warn(){ echo "${Y}WARN${Z} $*"; }
excluded(){ case " $EXCLUDED " in *" $1 "*) return 0;; *) return 1;; esac; }

echo "== PBS storage =="
pbs_store="$(awk '/^pbs:/{print $2; exit}' /etc/pve/storage.cfg 2>/dev/null)"
if [ -n "$pbs_store" ]; then
  pass "PBS storage '${pbs_store}' defined"
  st="$(pvesm status --storage "$pbs_store" 2>/dev/null | awk 'NR==2{print $3}')"
  [ "$st" = active ] && pass "  '${pbs_store}' is active" \
    || fail "  '${pbs_store}' not active (status: ${st:-unknown}) — pbs.home resolves? fingerprint right?"
else
  fail "no PBS storage in /etc/pve/storage.cfg — add it with 'pvesm add pbs ...'"
fi

echo "== backup job =="
if [ ! -s /etc/pve/jobs.cfg ] || ! grep -q '^vzdump:' /etc/pve/jobs.cfg 2>/dev/null; then
  fail "no vzdump backup job configured — add one (Datacenter -> Backup)"
  echo; echo "${R}${fails} check(s) failed${Z} — no backup job means nothing is protected (R4)."; exit 1
fi
pass "at least one vzdump job exists"

echo "== per-guest coverage (R4) =="
guests="$( { pct list 2>/dev/null | awk 'NR>1{print $1}'; qm list 2>/dev/null | awk 'NR>1{print $1}'; } | sort -un | tr '\n' ' ')"
[ -z "${guests// }" ] && { warn "no guests on this host"; }

# Which guests does jobs.cfg cover? (all=1 or listed in vmid) and not in the job's exclude.
cover="$(python3 - "$guests" <<'PY' 2>/dev/null
import sys
guests = sys.argv[1].split()
jobs = []; cur = None
try:
    for line in open('/etc/pve/jobs.cfg'):
        if line.startswith('vzdump:'):
            cur = {'all': False, 'vmid': set(), 'exclude': set()}; jobs.append(cur)
        elif cur is not None:
            s = line.strip()
            if s == 'all 1' or s.startswith('all 1'): cur['all'] = True
            elif s.startswith('vmid '):    cur['vmid']    = set(s[5:].replace(',', ' ').split())
            elif s.startswith('exclude '): cur['exclude'] = set(s[8:].replace(',', ' ').split())
except FileNotFoundError:
    pass
for g in guests:
    cov = any((j['all'] or g in j['vmid']) and g not in j['exclude'] for j in jobs)
    print(g, 'yes' if cov else 'no')
PY
)"
while read -r g cov; do
  [ -z "${g:-}" ] && continue
  if excluded "$g"; then
    if [ "$cov" = yes ]; then warn "  guest ${g} is IN a backup job but should be excluded (frigate 260G / PBS-self) — add it to the job's exclude"
    else pass "  guest ${g} excluded (deliberate)"; fi
  else
    if [ "$cov" = yes ]; then pass "  guest ${g} covered"
    else fail "  guest ${g} NOT in any backup job — unprotected (R4)"; fi
  fi
done <<< "$cover"

echo
if [ "$fails" = 0 ]; then
  echo "${G}ALL CHECKS PASSED — PBS storage active, every guest backed up (bar the deliberate exclusions).${Z}"
  echo "(This proves coverage, not restorability — G5's test restore is the real R4/R12 proof.)"; exit 0
else
  echo "${R}${fails} check(s) failed${Z} — inspect the failing item above."; exit 1
fi
