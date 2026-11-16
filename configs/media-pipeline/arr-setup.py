#!/usr/bin/env python3
"""arr-setup.py — wire the Arr stack over their APIs (root folders, qBittorrent
client + category on Sonarr/Radarr, Prowlarr applications + FlareSolverr proxy, and
qBittorrent's own ATM + save path + categories).

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
import argparse, json, os, sys, urllib.request, urllib.error, urllib.parse, http.cookiejar

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


def ensure_min_free_space(base, key, mb, apply):
    """Set Sonarr/Radarr's 'Minimum Free Space When Importing' so grabs stop cleanly
    before the pool fills (R7). Singleton config resource — GET, tweak, PUT it back."""
    cfg = http("GET", f"{base}/api/v3/config/mediamanagement", key)
    cur = cfg.get("minimumFreeSpaceWhenImporting")
    if cur == mb:
        print(f"    min free space: already {mb} MB")
        return
    if not apply:
        print(f"    min free space: WOULD set {cur} -> {mb} MB")
        return
    cfg["minimumFreeSpaceWhenImporting"] = mb
    http("PUT", f"{base}/api/v3/config/mediamanagement/{cfg['id']}", key, cfg)
    print(f"    min free space: set {mb} MB")


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
            # value used BY Sonarr/Radarr, which sit on the compose net → service name
            f["value"] = env.get("QBIT_SVC", "qbittorrent")
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


def configure_qbittorrent(env, apply):
    """Log into qBittorrent and set the few things the Arrs rely on: Automatic Torrent
    Management on, a default save path under /data/torrents, and the two categories the
    Arrs push to (same branch as the library so imports hardlink, not copy). qBittorrent
    has no native 'pause when disk is low' knob — that one stays a manual Options tweak."""
    # arr-setup itself runs on the LXC host, so it logs into qBit via the published port
    host = env.get("QBIT_HOST", "localhost")
    port = env.get("QBIT_PORT", "8080")
    base = f"http://{host}:{port}"
    user = env.get("QBIT_USER", "")
    pw = env.get("QBIT_PASS", "")
    # flat save path: /data/torrents exists on both mergerfs branches (stage-b base tree),
    # so the create policy never has to invent a subfolder. qbit_manage's cat map matches this.
    cats = {"tv-sonarr": "/data/torrents", "movies-radarr": "/data/torrents"}
    if not apply:
        print(f"    qBittorrent @ {base}: WOULD set ATM on, save path /data/torrents, "
              f"categories {', '.join(cats)}")
        return
    cj = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))

    def post(path, fields):
        data = urllib.parse.urlencode(fields).encode()
        req = urllib.request.Request(base + path, data=data)
        req.add_header("Referer", base)  # qBittorrent's WebUI CSRF check wants this
        return opener.open(req, timeout=15).read().decode()

    if post("/api/v2/auth/login", {"username": user, "password": pw}).strip() != "Ok.":
        raise RuntimeError("login failed (check QBIT_USER / QBIT_PASS in .env)")
    post("/api/v2/app/setPreferences", {"json": json.dumps(
        {"auto_tmm_enabled": True, "save_path": "/data/torrents",
         "torrent_changed_tmm_enabled": True, "save_path_changed_tmm_enabled": True})})
    for cat, path in cats.items():
        # createCategory is idempotent-ish; editCategory fixes the path if it already exists
        try:
            post("/api/v2/torrents/createCategory", {"category": cat, "savePath": path})
        except urllib.error.HTTPError:
            post("/api/v2/torrents/editCategory", {"category": cat, "savePath": path})
    print(f"    qBittorrent: ATM on, save path /data/torrents, categories {', '.join(cats)}")


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

    # Defaults assume this runs INSIDE LXC 210, reaching the apps on their published
    # ports via localhost. FlareSolverr stays a Docker service name because Prowlarr
    # (a compose service) is what calls it, over the compose network.
    sonarr = env.get("SONARR_URL", "http://localhost:8989")
    radarr = env.get("RADARR_URL", "http://localhost:7878")
    prowlarr = env.get("PROWLARR_URL", "http://localhost:9696")
    flare = env.get("FLARESOLVERR_URL", "http://flaresolverr:8191/")
    sk, rk, pk = env.get("SONARR_API_KEY"), env.get("RADARR_API_KEY"), env.get("PROWLARR_API_KEY")
    min_free = int(env.get("ARR_MIN_FREE_MB", "10240"))  # 10 GB default; override in .env

    if not all([sk, rk, pk]):
        print("  note: missing API key(s) — set them in .env. Dry run shows intended config anyway.")

    if sk:
        step("Sonarr", lambda: (
            ensure_root_folder(sonarr, sk, "/data/library/tv", args.apply),
            ensure_min_free_space(sonarr, sk, min_free, args.apply),
            ensure_qbit(sonarr, sk, "tv-sonarr", env, args.apply)))
    if rk:
        step("Radarr", lambda: (
            ensure_root_folder(radarr, rk, "/data/library/movies", args.apply),
            ensure_min_free_space(radarr, rk, min_free, args.apply),
            ensure_qbit(radarr, rk, "movies-radarr", env, args.apply)))
    if pk:
        step("Prowlarr", lambda: (
            ensure_prowlarr_proxy(prowlarr, pk, flare, args.apply),
            ensure_prowlarr_app(prowlarr, pk, "Sonarr", sonarr, sk, prowlarr, args.apply),
            ensure_prowlarr_app(prowlarr, pk, "Radarr", radarr, rk, prowlarr, args.apply)))
    if env.get("QBIT_USER"):
        step("qBittorrent", lambda: configure_qbittorrent(env, args.apply))

    if not args.apply:
        print("dry run — pass --apply to write. Indexers stay manual; profiles are Recyclarr's job.")


if __name__ == "__main__":
    main()
