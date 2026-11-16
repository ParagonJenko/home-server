#!/usr/bin/env python3
"""arr-setup.py — wire the Arr stack over their APIs (root folders, qBittorrent
client + category on Sonarr/Radarr, Prowlarr applications + FlareSolverr proxy).

Dry-run by default; --apply writes. Idempotent, and asks each app for its own
schema rather than hardcoding field names, so it survives Arr releases.
Indexers stay manual (they need your accounts). Quality profiles are Recyclarr's job.

Reads config from .env (gitignored) next to this file, e.g.:
  SONARR_URL=http://media-pipeline.home:8989
  SONARR_API_KEY=...
  RADARR_URL=http://media-pipeline.home:7878
  RADARR_API_KEY=...
  PROWLARR_URL=http://media-pipeline.home:9696
  PROWLARR_API_KEY=...
  QBIT_HOST=qbittorrent        # reachable by Docker service name on the compose net
  QBIT_PORT=8080
  QBIT_USER=admin
  QBIT_PASS=...
  FLARESOLVERR_URL=http://flaresolverr:8191/
Stdlib only — runs anywhere that can reach the Arr APIs.
"""
import argparse, json, os, sys, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))


def load_env():
    env = {}
    path = os.path.join(HERE, ".env")
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    env.update({k: v for k, v in os.environ.items() if k in (
        "SONARR_URL", "SONARR_API_KEY", "RADARR_URL", "RADARR_API_KEY",
        "PROWLARR_URL", "PROWLARR_API_KEY", "QBIT_HOST", "QBIT_PORT",
        "QBIT_USER", "QBIT_PASS", "FLARESOLVERR_URL")})
    return env


def http(method, url, api_key=None, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if api_key:
        req.add_header("X-Api-Key", api_key)
    with urllib.request.urlopen(req, timeout=15) as r:
        b = r.read().decode()
        return json.loads(b) if b.strip() else None


def ensure_root_folder(base, key, path, apply):
    existing = {r["path"] for r in http("GET", f"{base}/api/v3/rootfolder", key)}
    if path in existing:
        print(f"    root folder {path}: present")
        return
    if not apply:
        print(f"    root folder {path}: WOULD add")
        return
    http("POST", f"{base}/api/v3/rootfolder", key, {"path": path})
    print(f"    root folder {path}: added")


def ensure_qbit(base, key, category, env, apply):
    clients = http("GET", f"{base}/api/v3/downloadclient", key)
    if any(c.get("implementation") == "QBittorrent" for c in clients):
        print("    qBittorrent client: present")
        return
    if not apply:
        print(f"    qBittorrent client (category={category}): WOULD add")
        return
    schema = http("GET", f"{base}/api/v3/downloadclient/schema", key)
    tmpl = next(s for s in schema if s.get("implementation") == "QBittorrent")
    tmpl["name"] = "qBittorrent"
    tmpl["enable"] = True
    for f in tmpl.get("fields", []):
        n = f.get("name", "").lower()
        if n == "host":
            f["value"] = env.get("QBIT_HOST", "qbittorrent")
        elif n == "port":
            f["value"] = int(env.get("QBIT_PORT", "8080"))
        elif n == "username":
            f["value"] = env.get("QBIT_USER", "")
        elif n == "password":
            f["value"] = env.get("QBIT_PASS", "")
        elif "categor" in n:
            f["value"] = category
    http("POST", f"{base}/api/v3/downloadclient", key, tmpl)
    print(f"    qBittorrent client (category={category}): added")


def ensure_prowlarr_proxy(base, key, flare_url, apply):
    proxies = http("GET", f"{base}/api/v1/indexerProxy", key)
    if any(p.get("implementation") == "FlareSolverr" for p in proxies):
        print("    FlareSolverr proxy: present")
        return
    if not apply:
        print(f"    FlareSolverr proxy -> {flare_url}: WOULD add")
        return
    schema = http("GET", f"{base}/api/v1/indexerProxy/schema", key)
    tmpl = next(s for s in schema if s.get("implementation") == "FlareSolverr")
    tmpl["name"] = "FlareSolverr"
    for f in tmpl.get("fields", []):
        if f.get("name", "").lower() == "host":
            f["value"] = flare_url
    # tag it so indexers can opt in; Prowlarr needs at least one tag on the proxy
    http("POST", f"{base}/api/v1/indexerProxy", key, tmpl)
    print(f"    FlareSolverr proxy -> {flare_url}: added (tag it onto Cloudflare indexers)")


def ensure_prowlarr_app(base, key, impl, app_url, app_key, prowlarr_url, apply):
    apps = http("GET", f"{base}/api/v1/applications", key)
    if any(a.get("implementation") == impl for a in apps):
        print(f"    Prowlarr -> {impl}: present")
        return
    if not apply:
        print(f"    Prowlarr -> {impl} ({app_url}): WOULD add")
        return
    schema = http("GET", f"{base}/api/v1/applications/schema", key)
    tmpl = next(s for s in schema if s.get("implementation") == impl)
    tmpl["name"] = impl
    tmpl["syncLevel"] = "fullSync"
    for f in tmpl.get("fields", []):
        n = f.get("name", "").lower()
        if n == "prowlarrurl":
            f["value"] = prowlarr_url
        elif n == "baseurl":
            f["value"] = app_url
        elif n == "apikey":
            f["value"] = app_key
    http("POST", f"{base}/api/v1/applications", key, tmpl)
    print(f"    Prowlarr -> {impl} ({app_url}): added")


def step(label, fn):
    print(f"  {label}:")
    try:
        fn()
    except urllib.error.URLError as e:
        print(f"    !! skipped — API error: {e}")
    except StopIteration:
        print("    !! skipped — implementation not in this app's schema")
    except Exception as e:  # noqa: BLE001 — one app's failure must not abort the rest
        print(f"    !! skipped — {e}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="write changes (default: dry run)")
    args = ap.parse_args()
    env = load_env()
    print("arr-setup:", "APPLY" if args.apply else "DRY RUN")

    sonarr = env.get("SONARR_URL", "http://media-pipeline.home:8989")
    radarr = env.get("RADARR_URL", "http://media-pipeline.home:7878")
    prowlarr = env.get("PROWLARR_URL", "http://media-pipeline.home:9696")
    flare = env.get("FLARESOLVERR_URL", "http://flaresolverr:8191/")
    sk, rk, pk = env.get("SONARR_API_KEY"), env.get("RADARR_API_KEY"), env.get("PROWLARR_API_KEY")

    if not all([sk, rk, pk]):
        print("  note: missing API key(s) — set them in .env. Dry run shows intended config anyway.")

    if sk:
        step("Sonarr", lambda: (
            ensure_root_folder(sonarr, sk, "/data/library/tv", args.apply),
            ensure_qbit(sonarr, sk, "tv-sonarr", env, args.apply)))
    if rk:
        step("Radarr", lambda: (
            ensure_root_folder(radarr, rk, "/data/library/movies", args.apply),
            ensure_qbit(radarr, rk, "movies-radarr", env, args.apply)))
    if pk:
        step("Prowlarr", lambda: (
            ensure_prowlarr_proxy(prowlarr, pk, flare, args.apply),
            ensure_prowlarr_app(prowlarr, pk, "Sonarr", sonarr, sk, prowlarr, args.apply),
            ensure_prowlarr_app(prowlarr, pk, "Radarr", radarr, rk, prowlarr, args.apply)))

    if not args.apply:
        print("dry run — pass --apply to write. Indexers stay manual; profiles are Recyclarr's job.")


if __name__ == "__main__":
    main()
