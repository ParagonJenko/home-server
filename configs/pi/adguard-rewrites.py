#!/usr/bin/env python3
"""adguard-rewrites.py — read the address register out of ../../network.md and push
every DNS rewrite over AdGuard's API (18+ entries typed into a web form is how one
ends up wrong). Three groups: front names -> Nginx, backend names -> container,
hosts/cameras -> their own IP.

  --apply   write (default is dry run)
  --check   exit non-zero if a name documented in network.md isn't resolving as documented
            (run on a schedule so the resolver can't quietly drift from the doc)

AdGuard admin creds come from the environment or a gitignored file, never committed:
  ADGUARD_URL       (default http://127.0.0.1:8081)
  ADGUARD_USERNAME / ADGUARD_PASSWORD   (or a KEY=VALUE file at $ADGUARD_CREDS,
                                         default ./adguard.creds — gitignored)
Stdlib only, so it runs on the Pi with no pip install.
"""
import argparse, base64, json, os, re, sys, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
NETWORK_MD = os.path.join(HERE, "..", "..", "network.md")


def load_creds():
    user = os.environ.get("ADGUARD_USERNAME")
    pw = os.environ.get("ADGUARD_PASSWORD")
    cred_file = os.environ.get("ADGUARD_CREDS", os.path.join(HERE, "adguard.creds"))
    if (not user or not pw) and os.path.exists(cred_file):
        for line in open(cred_file):
            line = line.strip()
            if line.startswith("ADGUARD_USERNAME="):
                user = line.split("=", 1)[1]
            elif line.startswith("ADGUARD_PASSWORD="):
                pw = line.split("=", 1)[1]
    return user, pw


def api(base, path, user, pw, method="GET", payload=None):
    url = base.rstrip("/") + path
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if user and pw:
        tok = base64.b64encode(f"{user}:{pw}".encode()).decode()
        req.add_header("Authorization", "Basic " + tok)
    with urllib.request.urlopen(req, timeout=10) as r:
        body = r.read().decode()
        return json.loads(body) if body.strip() else None


def parse_register(md):
    """From '## Address register': the Nginx IP and a name->own-IP map."""
    name_to_ip, nginx_ip, in_table = {}, None, False
    for line in md.splitlines():
        if line.startswith("## Address register"):
            in_table = True
            continue
        if in_table and line.startswith("## "):
            break
        if in_table and line.startswith("|"):
            ipm = re.search(r"`(\d+\.\d+\.\d+\.\d+)`", line)
            if not ipm:
                continue
            ip = ipm.group(1)
            device = line.strip().strip("|").split("|")[0].lower()
            if "nginx" in device:
                nginx_ip = ip
            for nm in re.findall(r"([a-z0-9-]+\.home)", line):
                name_to_ip.setdefault(nm, ip)
    return nginx_ip, name_to_ip


def parse_groups(md):
    """From '## DNS rewrite groups': the three lists of names, verbatim."""
    g, sec = {1: [], 2: [], 3: []}, False
    for line in md.splitlines():
        if line.startswith("## DNS rewrite groups"):
            sec = True
            continue
        if sec and line.startswith("## "):
            break
        if not sec:
            continue
        s = line.lstrip()
        if s.startswith("1."):
            g[1] = re.findall(r"`([a-z0-9-]+\.home)`", line)
        elif s.startswith("2."):
            g[2] = re.findall(r"`([a-z0-9-]+\.home)`", line)
        elif s.startswith("3."):
            g[3] = re.findall(r"`([a-z0-9*.-]+)`", line)
    return g


def build_desired(nginx_ip, name_to_ip, groups):
    desired, unresolved = {}, []
    for nm in groups[1]:                       # front names -> Nginx
        if nginx_ip:
            desired[nm] = nginx_ip
        else:
            unresolved.append(nm)
    for nm in groups[2]:                       # backend names -> own IP
        (desired.__setitem__(nm, name_to_ip[nm]) if nm in name_to_ip else unresolved.append(nm))
    for tok in groups[3]:                       # hosts & cameras -> own IP
        if tok == "cam-*.home":
            for nm, ip in name_to_ip.items():
                if nm.startswith("cam-"):
                    desired[nm] = ip
        else:
            nm = tok if "." in tok else tok + ".home"
            (desired.__setitem__(nm, name_to_ip[nm]) if nm in name_to_ip else unresolved.append(nm))
    return desired, unresolved


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    md = open(NETWORK_MD).read()
    nginx_ip, name_to_ip = parse_register(md)
    desired, unresolved = build_desired(nginx_ip, name_to_ip, parse_groups(md))

    print(f"parsed {len(desired)} rewrites from network.md (Nginx IP: {nginx_ip}).")
    if unresolved:
        print("  !! no IP in the register for:", ", ".join(unresolved) +
              "  (fill the TBD rows, then re-run).")

    if not args.apply and not args.check:        # dry run
        for nm in sorted(desired):
            print(f"  {nm:<28} -> {desired[nm]}")
        print("dry run — pass --apply to push, --check to verify.")
        return

    base = os.environ.get("ADGUARD_URL", "http://127.0.0.1:8081")
    user, pw = load_creds()
    try:
        current = api(base, "/control/rewrite/list", user, pw) or []
    except urllib.error.URLError as e:
        sys.exit(f"!! AdGuard API unreachable at {base}: {e}")
    existing = {r["domain"]: r["answer"] for r in current}

    drift = {nm: ip for nm, ip in desired.items() if existing.get(nm) != ip}

    if args.check:
        if drift or unresolved:
            for nm, ip in sorted(drift.items()):
                print(f"  DRIFT {nm} -> have {existing.get(nm)!r}, want {ip!r}")
            sys.exit(1)
        print("check: all documented rewrites present and correct.")
        return

    for nm, ip in sorted(drift.items()):
        if nm in existing:                        # replace a wrong answer
            api(base, "/control/rewrite/delete", user, pw, "POST",
                {"domain": nm, "answer": existing[nm]})
        api(base, "/control/rewrite/add", user, pw, "POST", {"domain": nm, "answer": ip})
        print(f"  applied {nm} -> {ip}")
    print(f"apply: {len(drift)} rewrite(s) pushed, {len(desired) - len(drift)} already correct.")


if __name__ == "__main__":
    main()
