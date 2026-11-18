#!/usr/bin/env python3
"""Split the one runbook into two docs that reuse its engine/styling:
   rebuild-basic.html (critical path) + rebuild-extras.html (hardening & extras)."""
import json, re, pathlib

DOCS = pathlib.Path("/home/claude/home-server/docs")
html = (DOCS / "runbook.html").read_text()

# ---- locate the STAGES array (balanced bracket) ----
i = html.find("var STAGES ="); start = html.find("[", i)
depth = 0; instr = False; esc = False; q = ""; end = None
for j in range(start, len(html)):
    c = html[j]
    if instr:
        if esc: esc = False
        elif c == "\\": esc = True
        elif c == q: instr = False
        continue
    if c in "\"'": instr = True; q = c; continue
    if c == "[": depth += 1
    elif c == "]":
        depth -= 1
        if depth == 0: end = j; break
prefix, suffix = html[:start], html[end+1:]
stages = json.loads(html[start:end+1])
by_id = {s["id"]: s for st in stages for s in st["steps"]}
stage_by_id = {st["id"]: st for st in stages}

def steps(*ids): return [by_id[i] for i in ids]
def stage(sid, name, where, title, intro, step_ids):
    base = dict(stage_by_id.get(sid, {}))
    base.update({"id": sid, "name": name, "where": where, "title": title,
                 "intro": intro, "steps": steps(*step_ids)})
    return base

# ====== BASIC: natural build order, services + backups only ======
basic = [
    stage("A", "Host base", "NUC-1", stage_by_id["A"]["title"], stage_by_id["A"]["intro"],
          ["A0", "A1", "A2", "A3"]),
    stage("B", "Storage", "NUC-1", "Build the media pool",
          "Attach the DAS and build the mergerfs pool. (The fill test and the pull-a-disk break test that prove it are in Hardening &amp; Extras → Proofs.)",
          ["B1", "B2"]),
    stage("C", "Template", "NUC-1", stage_by_id["C"]["title"], stage_by_id["C"]["intro"],
          ["C1", "C2"]),
    stage("D", "Internal DNS", "Raspberry Pi", stage_by_id["D"]["title"], stage_by_id["D"]["intro"],
          ["D0", "D1", "D2", "D3"]),
    stage("E", "Media stack", "NUC-1", stage_by_id["E"]["title"], stage_by_id["E"]["intro"],
          ["E0", "E1", "E2", "E3", "E4"]),
    stage("F", "NUC-2 host base", "NUC-2", stage_by_id["F"]["title"], stage_by_id["F"]["intro"],
          ["F1"]),
    stage("G", "Frigate · HA · PBS", "NUC-2", "Frigate, Home Assistant, and backups",
          "Frigate NVR, Home Assistant, and PBS taking scheduled backups of every guest. (The restore proof and offsite sync are in Hardening &amp; Extras.)",
          ["G1", "G2", "G3", "G4", "G5"]),
]

# ====== EXTRAS: regrouped into clear categories ======
extras = [
    stage("P", "Proofs & break-tests", "Prove the guardrails",
          "Proofs & break-tests",
          "Deliberately break things to prove the guardrails hold before you trust them — the fill tests (R10), the pull-a-disk test, and the relocation test. None change how the stack runs; they're how you know it's safe.",
          ["B3", "B4", "B5", "I2", "I3"]),
    stage("R", "Backups — recovery & offsite", "NUC-2 · cloud",
          "Backups — recovery & offsite",
          "The backups themselves are set up in the core build (G3–G5). This is the half that proves and extends them: a real restore (R12) and the offsite cloud copy (R4/R12).",
          ["G6", "G7"]),
    stage("M", "Monitoring & alerting", "Pi + NUCs",
          "Monitoring & alerting",
          "Observability — Prometheus/Grafana/Alertmanager, node + app exporters, and a proven Discord alert path. Alerts inform; they never protect (R11), so none of this affects whether the stack works.",
          ["H1", "H2", "H3", "H4", "H5"]),
    stage("N", "Remote access", "Everything",
          "Remote access",
          "Tailscale for portable remote access by stable name, with no port forwards (R20/R23). The stack works on the LAN without it; this is how you reach it from anywhere.",
          ["I1"]),
    stage("S", "Resilience & lifecycle", "Everywhere",
          "Resilience & lifecycle",
          "What keeps the build trustworthy over time: UPS + graceful shutdown (R22), off-box secrets (R21), SMART/temperature alerts (R24), unattended updates with rollback (R25), and data classed by what's re-downloadable (R26).",
          ["J1", "J2", "J3", "J4", "J5", "J6"]),
    stage("K", "Local inference", "Future · optional", stage_by_id["K"]["title"], stage_by_id["K"]["intro"],
          ["K0", "K1", "K2", "K3"]),
    stage("L", "Future upgrades", "Roadmap · as hardware/time allows", stage_by_id["L"]["title"], stage_by_id["L"]["intro"],
          ["L1", "L2", "L4", "L5"]),  # L3 was promoted to base (B2); drop it here
]

def build(stages_data, title, sub, kicker, h2, lead_html, stage_list_html, start_anchor):
    body = prefix + json.dumps(stages_data, ensure_ascii=False) + suffix
    reps = [
        ("<title>Proxmox Rebuild Runbook</title>", f"<title>{title}</title>"),
        ("<h1>Proxmox Rebuild Runbook</h1>", f"<h1>{title}</h1>"),
        ('<span class="sub">Stages A–K</span>', f'<span class="sub">{sub}</span>'),
        ("Clean build · Proxmox VE 9.2 · verified Aug 2026", kicker),
        ("Build the homelab in order, and prove each guardrail before the next one leans on it.", h2),
        ('<p><strong>Kit:</strong> two Beelink NUCs, a Raspberry Pi, a 2×4TB DAS, and a 2TB USB HDD (PBS backup datastore, Stage E).</p>', lead_html),
        ('Start at <a href="#stage-A">A0</a>.', f'Start at <a href="{start_anchor}">the top</a>.'),
    ]
    for a, b in reps:
        if a not in body: raise SystemExit(f"replace target missing: {a[:50]!r}")
        body = body.replace(a, b)
    # swap the "What each stage does" list
    m = re.search(r'<details class="callout note"><summary class="ctitle">What each stage does</summary>.*?</details>', body, re.S)
    if not m: raise SystemExit("stage-list details block not found")
    body = body.replace(m.group(0), f'<details class="callout note"><summary class="ctitle">What\'s in here</summary>{stage_list_html}</details>')
    return body

basic_list = ("<ul>"
    "<li><strong>A</strong> — host base (NUC-1).</li>"
    "<li><strong>B</strong> — storage: build the media pool.</li>"
    "<li><strong>C</strong> — container template.</li>"
    "<li><strong>D</strong> — internal DNS on the Pi.</li>"
    "<li><strong>E</strong> — media stack (NUC-1).</li>"
    "<li><strong>F</strong> — host base (NUC-2).</li>"
    "<li><strong>G</strong> — Frigate, Home Assistant + PBS backups (NUC-2).</li>"
    "</ul><p>Proofs, monitoring, remote access, resilience and future upgrades live in the companion <strong>Hardening &amp; Extras</strong> doc.</p>")

extras_list = ("<ul>"
    "<li><strong>P</strong> — proofs &amp; break-tests (fill / pull-disk / relocation).</li>"
    "<li><strong>R</strong> — backups: restore proof + offsite.</li>"
    "<li><strong>M</strong> — monitoring &amp; alerting.</li>"
    "<li><strong>N</strong> — remote access (Tailscale).</li>"
    "<li><strong>S</strong> — resilience &amp; lifecycle (UPS, SMART, updates).</li>"
    "<li><strong>K</strong> — local inference (future).</li>"
    "<li><strong>L</strong> — future upgrades.</li>"
    "</ul><p>The core build is in the companion <strong>Bare-Metal Rebuild</strong> doc.</p>")

basic_html = build(basic, "Bare-Metal Rebuild", "The critical path",
    "Bare-metal rebuild · the critical path",
    "Get the stack running: host, storage, DNS, services, Frigate/HA, and backups.",
    '<p><strong>Kit:</strong> two Beelink NUCs, a Raspberry Pi, a 2×4TB DAS, and a 2TB USB HDD (PBS backup datastore).</p><p>This is the <strong>minimum to a working, backed-up stack</strong> on the LAN. Everything that proves, monitors, hardens or future-proofs it is in the companion <strong>Hardening &amp; Extras</strong> doc.</p>',
    basic_list, "#stage-A")

extras_html = build(extras, "Hardening & Extras", "Beyond a working stack",
    "Hardening & extras · beyond a working stack",
    "Everything that proves, observes, hardens, and future-proofs the build.",
    '<p><strong>None of this is needed to get services running</strong> — that\'s the <strong>Bare-Metal Rebuild</strong> doc. This is what makes the stack trustworthy, observable, portable and resilient.</p>',
    extras_list, "#stage-P")

(DOCS / "rebuild-basic.html").write_text(basic_html)
(DOCS / "rebuild-extras.html").write_text(extras_html)
print("basic:", len(basic_html), "bytes,", len(basic), "stages")
print("extras:", len(extras_html), "bytes,", len(extras), "stages")
