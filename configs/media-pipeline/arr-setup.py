#!/usr/bin/env python3
"""arr-setup.py — wire the Arr stack over their APIs (root folders, qBittorrent
client + category on Sonarr/Radarr, Prowlarr applications + FlareSolverr proxy,
qBittorrent's own ATM + save path + categories, Bazarr's Sonarr/Radarr
connections + a default English language profile, and Forms authentication
on Sonarr/Radarr/Prowlarr with a generated login).

Dry-run by default; --apply writes. Idempotent, and asks each app for its own
schema rather than hardcoding field names, so it survives Arr releases.
Indexers stay manual (they need your accounts). Quality profiles are Recyclarr's job.

Reads config from .env (gitignored) next to this file, e.g.:
  SONARR_URL=http://media-pipeline.home.alexjenkinson.com:8989
  SONARR_API_KEY=...
  RADARR_URL=http://media-pipeline.home.alexjenkinson.com:7878
  RADARR_API_KEY=...
  PROWLARR_URL=http://media-pipeline.home.alexjenkinson.com:9696
  PROWLARR_API_KEY=...
  QBIT_HOST=qbittorrent        # reachable by Docker service name on the compose net
  QBIT_PORT=8080
  QBIT_USER=admin
  QBIT_PASS=...
  FLARESOLVERR_URL=http://flaresolverr:8191/
Stdlib only — runs anywhere that can reach the Arr APIs.
"""
import argparse, json, os, secrets, sys, urllib.request, urllib.error, urllib.parse
from http.cookiejar import CookieJar  # imported by name: the http() func below shadows the module

HERE = os.path.dirname(os.path.abspath(__file__))


def upsert_env(key, value):
    """Set key=value in the .env next to this script (replace in place, or append), so a
    generated credential survives re-runs."""
    path = os.path.join(HERE, ".env")
    lines = open(path).read().splitlines() if os.path.exists(path) else []
    for i, ln in enumerate(lines):
        if ln.startswith(key + "="):
            lines[i] = f"{key}={value}"
            break
    else:
        lines.append(f"{key}={value}")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


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


def ensure_hardlinks(base, key, apply):
    """Pin copyUsingHardlinks=true on Sonarr/Radarr. The default is already true, but pin it so a
    rebuild can't drift to copying — a copy doubles disk use and piles read+write I/O on the slow
    mergerfs/USB pool, instead of an instant hardlink (R1). (mergerfs links fine within a branch;
    verified 2026-11-19.)"""
    cfg = http("GET", f"{base}/api/v3/config/mediamanagement", key)
    if cfg.get("copyUsingHardlinks") is True:
        print("    hardlinks on import: already enabled")
        return
    if not apply:
        print(f"    hardlinks on import: WOULD enable (was {cfg.get('copyUsingHardlinks')})")
        return
    cfg["copyUsingHardlinks"] = True
    http("PUT", f"{base}/api/v3/config/mediamanagement/{cfg['id']}", key, cfg)
    print("    hardlinks on import: enabled")


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
    cj = CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))

    def post(path, fields):
        data = urllib.parse.urlencode(fields).encode()
        req = urllib.request.Request(base + path, data=data)
        req.add_header("Referer", base)  # qBittorrent's WebUI CSRF check wants this
        return opener.open(req, timeout=15).read().decode()

    # Success is "Ok." (older qBittorrent) or an empty 204 body (5.x+). Only an explicit
    # "Fails." is wrong credentials; a ban is a 4xx and raises before we get here.
    if post("/api/v2/auth/login", {"username": user, "password": pw}).strip() == "Fails.":
        raise RuntimeError("login failed (check QBIT_USER / QBIT_PASS in .env)")
    post("/api/v2/app/setPreferences", {"json": json.dumps(
        {"auto_tmm_enabled": True, "save_path": "/data/torrents",
         "torrent_changed_tmm_enabled": True, "save_path_changed_tmm_enabled": True,
         # --- I/O hardening (2026-11-19): a USB DAS chokes on many concurrent random seeding
         # reads. Cap how many torrents are actively seeding at once and stop them running away. ---
         "queueing_enabled": True,
         "max_active_downloads": 3, "max_active_uploads": 3, "max_active_torrents": 3,
         "dont_count_slow_torrents": False,   # was true -> the active limit was bypassed by idle seeders
         "max_connec": 200, "max_connec_per_torrent": 100,
         "max_uploads": 8, "max_uploads_per_torrent": 4,
         "max_ratio_enabled": True, "max_ratio": 2.0, "max_ratio_act": 0,     # 0 = pause at ratio 2
         "max_seeding_time_enabled": True, "max_seeding_time": 20160})})      # ...or after 14 days
    for cat, path in cats.items():
        # createCategory is idempotent-ish; editCategory fixes the path if it already exists
        try:
            post("/api/v2/torrents/createCategory", {"category": cat, "savePath": path})
        except urllib.error.HTTPError:
            post("/api/v2/torrents/editCategory", {"category": cat, "savePath": path})
    print(f"    qBittorrent: ATM on, save path /data/torrents, seeding caps (3 active, ratio 2 / 14d), "
          f"categories {', '.join(cats)}")


def ensure_tag(base, apiver, key, label):
    """Return the id of the tag with this label, creating it if missing. Prowlarr stores
    labels lowercased, so match and create with the lowercase form."""
    label = label.lower()
    for t in http("GET", f"{base}/api/{apiver}/tag", key):
        if t.get("label") == label:
            return t["id"]
    return http("POST", f"{base}/api/{apiver}/tag", key, {"label": label})["id"]


def ensure_prowlarr_proxy(base, key, flare_url, apply):
    # The proxy only applies to indexers carrying its tag, so the 'flaresolverr' tag must
    # exist and be on the proxy first — then adding a Cloudflare indexer is just picking it.
    proxies = http("GET", f"{base}/api/v1/indexerProxy", key)
    existing = next((p for p in proxies if p.get("implementation") == "FlareSolverr"), None)
    if not apply:
        where = "present" if existing else f"-> {flare_url}: WOULD add"
        print(f"    FlareSolverr proxy: {where} (ensuring 'flaresolverr' tag)")
        return
    tag_id = ensure_tag(base, "v1", key, "flaresolverr")
    if existing:  # already there (maybe untagged from an earlier run) — ensure the tag is on it
        if tag_id not in (existing.get("tags") or []):
            existing["tags"] = (existing.get("tags") or []) + [tag_id]
            http("PUT", f"{base}/api/v1/indexerProxy/{existing['id']}", key, existing)
            print("    FlareSolverr proxy: present — added the 'flaresolverr' tag")
        else:
            print("    FlareSolverr proxy: present, 'flaresolverr' tag already set")
        return
    schema = http("GET", f"{base}/api/v1/indexerProxy/schema", key)
    tmpl = next(s for s in schema if s.get("implementation") == "FlareSolverr")
    tmpl["name"] = "FlareSolverr"
    tmpl["tags"] = [tag_id]
    for f in tmpl.get("fields", []):
        if f.get("name", "").lower() == "host":
            f["value"] = flare_url
    http("POST", f"{base}/api/v1/indexerProxy", key, tmpl)
    print(f"    FlareSolverr proxy -> {flare_url}: added, tagged 'flaresolverr'")


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


def ensure_auth(label, base, apiver, key, user, pw, apply):
    """Set Forms authentication on a Servarr app to clear the 'authentication required'
    nag. authenticationRequired=enabled (not disabledForLocalAddresses — that demands an
    AllowedHosts whitelist that would have to cover the service name, the front name and
    the IP, and silently blocks whatever it misses). API-key access bypasses the login, so
    all automation and inter-app calls keep working; only the WebUI asks for a login, from
    any host. Changing this restarts the app, so it runs as the last step."""
    cfg = http("GET", f"{base}/api/{apiver}/config/host", key)
    if (cfg.get("authenticationMethod") or "none").lower() not in ("none", "external"):
        print(f"    {label}: auth already set ({cfg.get('authenticationMethod')})")
        return
    if not apply:
        print(f"    {label}: WOULD set forms auth (login required; API keys bypass it)")
        return
    cfg["authenticationMethod"] = "forms"
    cfg["authenticationRequired"] = "enabled"
    cfg["username"] = user
    cfg["password"] = pw
    cfg["passwordConfirmation"] = pw  # the API validates this matches password
    http("PUT", f"{base}/api/{apiver}/config/host/{cfg['id']}", key, cfg)
    print(f"    {label}: forms auth set — app will restart (API keys unaffected)")


def bazarr_apikey(conf_path):
    """Read auth.apikey out of Bazarr's config.yaml without a YAML dependency. Tracks the
    current top-level section (unindented line ending in ':') and returns the apikey under
    'auth' — not the sonarr/radarr apikeys that also live in the file."""
    section = None
    try:
        for line in open(conf_path):
            if line.strip() and not line[0].isspace() and line.rstrip().endswith(":"):
                section = line.strip().rstrip(":")
            elif section == "auth" and line.strip().startswith("apikey:"):
                return line.split("apikey:", 1)[1].strip()
    except FileNotFoundError:
        return None
    return None


def configure_bazarr(env, sk, rk, apply):
    """Configure Bazarr over its settings API: Sonarr/Radarr connections (by compose
    service name), an English language filter + profile, and that profile as the default
    for series and movies. Subtitle providers still need your accounts. Bazarr's own API
    key is read from its config.yaml. One POST /api/system/settings drives all of it."""
    conf = env.get("BAZARR_CONFIG", "/opt/bazarr/config/config/config.yaml")
    base = env.get("BAZARR_URL", "http://localhost:6767")
    apikey = bazarr_apikey(conf)
    if not apikey:
        print(f"    no API key in {conf} yet — has Bazarr booted once?")
        return
    if not apply:
        print("    WOULD set Sonarr/Radarr connections + an English profile as default")
        return
    # Bazarr reaches the Arrs over the compose network, so service names, not localhost.
    profile = [{"profileId": 1, "name": "English", "cutoff": None,
                "items": [{"id": 1, "language": "en", "audio_exclude": "False",
                           "hi": "False", "forced": "False"}],
                "mustContain": [], "mustNotContain": [], "originalFormat": None, "tag": None}]
    fields = [
        ("settings-general-use_sonarr", "true"),
        ("settings-sonarr-ip", env.get("SONARR_SVC_HOST", "sonarr")),
        ("settings-sonarr-port", "8989"),
        ("settings-sonarr-base_url", "/"),
        ("settings-sonarr-ssl", "false"),
        ("settings-sonarr-apikey", sk),
        ("settings-general-use_radarr", "true"),
        ("settings-radarr-ip", env.get("RADARR_SVC_HOST", "radarr")),
        ("settings-radarr-port", "7878"),
        ("settings-radarr-base_url", "/"),
        ("settings-radarr-ssl", "false"),
        ("settings-radarr-apikey", rk),
        ("languages-enabled", "en"),
        ("languages-profiles", json.dumps(profile)),
        ("settings-general-serie_default_enabled", "true"),
        ("settings-general-serie_default_profile", "1"),
        ("settings-general-movie_default_enabled", "true"),
        ("settings-general-movie_default_profile", "1"),
    ]
    url = base + "/api/system/settings?" + urllib.parse.urlencode({"apikey": apikey})
    req = urllib.request.Request(url, data=urllib.parse.urlencode(fields).encode())
    req.add_header("X-API-KEY", apikey)  # Bazarr accepts the key as header or query param
    urllib.request.urlopen(req, timeout=20)  # 204 on success; 406 (validation) raises
    print("    Sonarr + Radarr connected; English profile set as the default for both")


def step(label, fn):
    print(f"  {label}:")
    try:
        fn()
    except urllib.error.HTTPError as e:  # subclass of URLError — catch first, show the body
        body = ""
        try:
            body = e.read().decode()[:500]
        except Exception:
            pass
        print(f"    !! skipped — HTTP {e.code} {e.reason}: {body}")
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

    # Two kinds of URL. These are how THIS script reaches each app's API — it runs on
    # the LXC host, so localhost + the published ports.
    sonarr = env.get("SONARR_URL", "http://localhost:8989")
    radarr = env.get("RADARR_URL", "http://localhost:7878")
    prowlarr = env.get("PROWLARR_URL", "http://localhost:9696")
    # These are how one CONTAINER reaches another (Prowlarr->Sonarr, Sonarr->FlareSolverr):
    # over the compose network by service name. localhost there means the container itself.
    sonarr_svc = env.get("SONARR_SVC", "http://sonarr:8989")
    radarr_svc = env.get("RADARR_SVC", "http://radarr:7878")
    prowlarr_svc = env.get("PROWLARR_SVC", "http://prowlarr:9696")
    flare = env.get("FLARESOLVERR_URL", "http://flaresolverr:8191/")
    sk, rk, pk = env.get("SONARR_API_KEY"), env.get("RADARR_API_KEY"), env.get("PROWLARR_API_KEY")
    min_free = int(env.get("ARR_MIN_FREE_MB", "10240"))  # 10 GB default; override in .env

    if not all([sk, rk, pk]):
        print("  note: missing API key(s) — set them in .env. Dry run shows intended config anyway.")

    # Shared WebUI credential for the auth step. Generate once and persist to .env so it's
    # stable across re-runs; it's bypassed on the LAN so it's rarely typed, but keep it safe.
    auth_user = env.get("ARR_AUTH_USER", "admin")
    auth_pass = env.get("ARR_AUTH_PASS", "")
    if args.apply and not auth_pass:
        auth_pass = secrets.token_urlsafe(18)
        upsert_env("ARR_AUTH_USER", auth_user)
        upsert_env("ARR_AUTH_PASS", auth_pass)
        print(f"  generated Arr WebUI login — SAVE to your vault:  {auth_user} / {auth_pass}")

    if sk:
        step("Sonarr", lambda: (
            ensure_root_folder(sonarr, sk, "/data/library/tv", args.apply),
            ensure_min_free_space(sonarr, sk, min_free, args.apply),
            ensure_hardlinks(sonarr, sk, args.apply),
            ensure_qbit(sonarr, sk, "tv-sonarr", env, args.apply)))
    if rk:
        step("Radarr", lambda: (
            ensure_root_folder(radarr, rk, "/data/library/movies", args.apply),
            ensure_min_free_space(radarr, rk, min_free, args.apply),
            ensure_hardlinks(radarr, rk, args.apply),
            ensure_qbit(radarr, rk, "movies-radarr", env, args.apply)))
    if pk:
        step("Prowlarr", lambda: (
            ensure_prowlarr_proxy(prowlarr, pk, flare, args.apply),
            ensure_prowlarr_app(prowlarr, pk, "Sonarr", sonarr_svc, sk, prowlarr_svc, args.apply),
            ensure_prowlarr_app(prowlarr, pk, "Radarr", radarr_svc, rk, prowlarr_svc, args.apply)))
    if env.get("QBIT_USER"):
        step("qBittorrent", lambda: configure_qbittorrent(env, args.apply))
    if sk and rk:
        step("Bazarr", lambda: configure_bazarr(env, sk, rk, args.apply))
    # Auth LAST: setting it restarts each app, so do it after all inter-app wiring.
    step("Authentication", lambda: [
        ensure_auth("Sonarr", sonarr, "v3", sk, auth_user, auth_pass, args.apply) if sk else None,
        ensure_auth("Radarr", radarr, "v3", rk, auth_user, auth_pass, args.apply) if rk else None,
        ensure_auth("Prowlarr", prowlarr, "v1", pk, auth_user, auth_pass, args.apply) if pk else None])

    if not args.apply:
        print("dry run — pass --apply to write. Indexers stay manual; profiles are Recyclarr's job.")


if __name__ == "__main__":
    main()
