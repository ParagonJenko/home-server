#!/usr/bin/env python3
"""maintainerr-seed-rules.py — seed space-reclaim rule groups in Maintainerr, review-driven.

The goal: free real disk space WITHOUT binning hard-to-replace content. Old/rare titles are
harder to re-acquire than recent popular ones, so a blind "delete old unwatched" rule does the
wrong thing. This builds a smarter, Discord-reviewed workflow instead.

Per library it creates TWO groups:
  * "Clear — …"  (auto-delete): big + unwatched + RECENT (released within --old-years). These
    are the easy-to-re-grab files, so they auto-delete after a --grace day window, with a Discord
    warning first.
  * "Review — … (old)" (NEVER auto-deletes): big + unwatched + OLD (released over --old-years
    ago). These might be rare, so they are only *raised* in Discord for a human to tag 'keep'
    or delete by hand.

Both groups gate on, all AND'd:
  * file over --min-size-gb        (only big files are worth clearing; small rare files are left
                                     alone — Radarr fileSize / Sonarr show disk size)
  * added over --days ago          (never touch newly-grabbed media)
  * not watched in --days          (never-watched stays in; actively-watched is excluded)
  * NOT tagged --keep-tag          (tag a title 'keep' in Radarr/Sonarr to protect it forever)
Shows additionally require the series to have ENDED in Sonarr (never a still-airing show).

Protecting a title (easy for anyone): tag it '<keep-tag>' in Radarr/Sonarr, OR open Maintainerr
and click "exclude" on it in the collection. Either keeps it out for good.

Discord: set up ONE Discord notification in Maintainerr first (Settings -> Notifications -> add
Discord webhook) and tick the events "Media added to collection" and "Media about to be handled".
This script attaches it to every group it creates. Run with --no-notify to skip Discord.

Safety: DRY-RUN by default (prints payloads, changes nothing; add --apply). Even applied, a group
never runs on creation, the "Clear" group holds a match for --grace days before deleting, and the
"Review" group never deletes at all. Idempotent: a group whose name exists is skipped.

Adapts to both Maintainerr API generations (2.x /api/plex, newer /api/media-server). Property and
library IDs are resolved from the live instance by name, so it survives version drift.

  Preview:  ./maintainerr-seed-rules.py
  Apply:    ./maintainerr-seed-rules.py --apply
  + shows:  ./maintainerr-seed-rules.py --apply --shows
"""
import argparse
import datetime
import json
import os
import sys
import urllib.error
import urllib.request

DEFAULT_URL = os.environ.get("MAINTAINERR_URL", "http://media-pipeline.home.alexjenkinson.com:6246")
DAY = 86400

# Enum values from Maintainerr's rule constants (stable/append-only across 2.x and main).
RULE_OP_AND = 0          # RuleOperators.AND  (null = first rule of a section)
POSS_BIGGER = 0          # RulePossibility.BIGGER
POSS_EQUALS = 2          # RulePossibility.EQUALS
POSS_BEFORE = 5          # RulePossibility.BEFORE   (date further in the past than the value)
POSS_AFTER = 6           # RulePossibility.AFTER    (date more recent than the value)
POSS_NOT_CONTAINS = 9    # RulePossibility.NOT_CONTAINS
RULETYPE_NUMBER = 0      # customVal.ruleTypeId: plain number, OR relative duration (seconds)
RULETYPE_DATE = 1        # customVal.ruleTypeId: absolute date (ISO 'YYYY-MM-DD')
RULETYPE_TEXT = 2        # customVal.ruleTypeId: text (valid against a TEXT_LIST property too)
RULETYPE_BOOL = 3        # customVal.ruleTypeId: boolean ("1"/"0")
ARRACTION_DELETE = 0     # ServarrAction.DELETE
ARRACTION_DO_NOTHING = 4 # ServarrAction.DO_NOTHING (review-only group: never deletes)
EPLEX_MOVIES = 1         # EPlexDataType.MOVIES  (2.x numeric dataType)
EPLEX_SHOWS = 2          # EPlexDataType.SHOWS


def _req(url, method="GET", body=None, timeout=20):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw.strip() else None)
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        reason = getattr(e, "reason", e)
        print(f"  ! Maintainerr did not respond for {url}: {reason}\n"
              "    Usually means Maintainerr can't reach Plex (its API blocks on the Plex query).\n"
              "    In Settings -> Plex, pick the plain local-IP server (not the .plex.direct one) and save.",
              file=sys.stderr)
        sys.exit(2)


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def get_libraries(base):
    """Return (libraries, flavor). flavor 'plex' = 2.x API, 'mediaserver' = newer API.
    Each library normalised to {id, title, type('movie'|'show')}."""
    st, data = _req(f"{base}/api/plex/libraries")
    if st == 200 and isinstance(data, list):
        libs = [{"id": l.get("key"), "title": l.get("title"), "type": l.get("type")}
                for l in data if l.get("type") in ("movie", "show")]
        return libs, "plex"
    st2, data2 = _req(f"{base}/api/media-server/libraries")
    if st2 == 200 and isinstance(data2, list):
        libs = [{"id": l.get("id"), "title": l.get("title"), "type": l.get("type")}
                for l in data2 if l.get("type") in ("movie", "show")]
        return libs, "mediaserver"
    die("could not read libraries from either /api/plex/libraries "
        f"(HTTP {st}) or /api/media-server/libraries (HTTP {st2}). "
        "Connect your media server (Plex) in the Maintainerr UI first, then re-run.")


def resolve_prop(constants, app_name, prop_name):
    """Return [appId, propId] for a property, looked up BY NAME — never hardcoded."""
    for app in constants.get("applications", []):
        if app.get("name", "").lower() == app_name.lower():
            for p in app.get("props", []):
                if p.get("name") == prop_name:
                    return [app["id"], p["id"]]
            die(f"Maintainerr has no '{prop_name}' property on {app_name} in this version — "
                f"its rule constants have changed; update this script.")
    die(f"Maintainerr exposes no '{app_name}' application — is it connected in the UI?")


# --- rule builders. section/operator drive AND/OR; customVal carries the second value. ---
def _rule(section, operator, action, firstval, custom=None):
    r = {"operator": operator, "action": action, "firstVal": firstval, "section": section}
    if custom is not None:
        r["customVal"] = custom
    return r


def rel_date(section, operator, action, firstval, seconds):   # relative "N days/seconds ago"
    return _rule(section, operator, action, firstval, {"ruleTypeId": RULETYPE_NUMBER, "value": str(seconds)})


def abs_date(section, operator, action, firstval, iso):       # absolute cutoff date
    return _rule(section, operator, action, firstval, {"ruleTypeId": RULETYPE_DATE, "value": iso})


def number(section, operator, action, firstval, n):           # plain number compare (e.g. MB)
    return _rule(section, operator, action, firstval, {"ruleTypeId": RULETYPE_NUMBER, "value": str(int(n))})


def text_in_list(section, operator, action, firstval, text):  # tag membership on a TEXT_LIST
    return _rule(section, operator, action, firstval, {"ruleTypeId": RULETYPE_TEXT, "value": text})


def boolean(section, operator, action, firstval, truthy):
    return _rule(section, operator, action, firstval, {"ruleTypeId": RULETYPE_BOOL, "value": "1" if truthy else "0"})


def build_group(name, desc, library, flavor, rules, arr, arr_action, grace, notify_ids):
    if flavor == "plex":
        data_type = EPLEX_MOVIES if library["type"] == "movie" else EPLEX_SHOWS
        try:
            library_id = int(library["id"])           # RulesDto.libraryId is numeric in 2.x
        except (TypeError, ValueError):
            library_id = library["id"]
    else:
        data_type = library["type"]                   # 'movie' | 'show'
        library_id = str(library["id"])
    collection = {"keepLogsForMonths": 6, "visibleOnHome": False}
    if grace is not None:                             # review-only groups omit this -> never auto-delete
        collection["deleteAfterDays"] = grace
    group = {
        "libraryId": library_id,
        "name": name,
        "description": desc,
        "isActive": True,
        "useRules": True,
        "arrAction": arr_action,
        "dataType": data_type,
        "collection": collection,
        "rules": rules,
        # MUST be a list (not omitted): on undefined Maintainerr runs .add(undefined), writing a
        # null notificationId that trips a NOT NULL constraint and fails the whole group.
        "notifications": [{"id": nid} for nid in notify_ids],
    }
    if arr is not None:
        group[arr[0]] = arr[1]
    return group


def common_rules(props, days, min_mb, keep_tag):
    """The AND gates shared by both groups. First rule (size) is the OR seed for the set."""
    secs = days * DAY
    return [
        number(0, None, POSS_BIGGER, props["size"], min_mb),            # seed: files over the floor
        rel_date(0, RULE_OP_AND, POSS_BEFORE, props["added"], secs),    # AND added > N days ago
        rel_date(0, RULE_OP_AND, POSS_BEFORE, props["watched"], secs),  # AND not watched in N days
        text_in_list(0, RULE_OP_AND, POSS_NOT_CONTAINS, props["tags"], keep_tag),  # AND not tagged keep
    ]


def main():
    ap = argparse.ArgumentParser(description="Seed review-driven space-reclaim rules in Maintainerr.")
    ap.add_argument("--url", default=DEFAULT_URL, help=f"Maintainerr base URL (default {DEFAULT_URL})")
    ap.add_argument("--apply", action="store_true", help="actually create the groups (default: preview only)")
    ap.add_argument("--shows", action="store_true", help="also seed show-library groups (off by default)")
    ap.add_argument("--days", type=int, default=90, help="unwatched/added window in days (default 90)")
    ap.add_argument("--old-years", type=int, default=6, help="age split: older than this = review-only (default 6)")
    ap.add_argument("--min-size-gb", type=float, default=15, help="movie file size floor in GB (default 15)")
    ap.add_argument("--show-min-size-gb", type=float, default=40, help="show total disk floor in GB (default 40)")
    ap.add_argument("--grace", type=int, default=7, help="deleteAfterDays grace for the Clear group (default 7)")
    ap.add_argument("--keep-tag", default="keep", help="Radarr/Sonarr tag that protects a title (default 'keep')")
    ap.add_argument("--no-notify", action="store_true", help="don't attach Discord notifications")
    args = ap.parse_args()
    base = args.url.rstrip("/")
    cutoff = (datetime.date.today() - datetime.timedelta(days=int(args.old_years * 365.25))).isoformat()

    print(f"Maintainerr: {base}   mode: {'APPLY' if args.apply else 'DRY-RUN (no changes)'}")
    print(f"size floor: movies >{args.min_size_gb}GB, shows >{args.show_min_size_gb}GB | "
          f"age split: released before {cutoff} = review-only | keep tag: '{args.keep_tag}'\n")

    # 1) Libraries + API generation.
    libs, flavor = get_libraries(base)
    movie_libs = [l for l in libs if l["type"] == "movie"]
    show_libs = [l for l in libs if l["type"] == "show"]
    print(f"API: {flavor}   libraries: "
          + ", ".join(f"{l['title']} ({l['type']}, id={l['id']})" for l in libs) + "\n")

    # 2) Resolve every property by name (version-robust).
    st, constants = _req(f"{base}/api/rules/constants")
    if st != 200 or not isinstance(constants, dict):
        die(f"could not read /api/rules/constants (HTTP {st}).")
    movie_props = {
        "size":    resolve_prop(constants, "Radarr", "fileSize"),       # MB
        "added":   resolve_prop(constants, "Plex", "addDate"),
        "watched": resolve_prop(constants, "Plex", "lastViewedAt"),
        "release": resolve_prop(constants, "Plex", "releaseDate"),
        "tags":    resolve_prop(constants, "Radarr", "tags"),
    }
    if args.shows:
        show_props = {
            "size":    resolve_prop(constants, "Sonarr", "diskSizeEntireShow"),  # MB
            "added":   resolve_prop(constants, "Plex", "addDate"),
            "watched": resolve_prop(constants, "Plex", "sw_lastWatched"),
            "release": resolve_prop(constants, "Sonarr", "firstAirDate"),
            "tags":    resolve_prop(constants, "Sonarr", "tags"),
            "ended":   resolve_prop(constants, "Sonarr", "ended"),
        }

    # 3) Arr instance IDs — only the newer API ties a group to one; 2.x uses the single config.
    def first_arr_id(path, label):
        s, data = _req(f"{base}{path}")
        if s == 200 and isinstance(data, list) and data:
            return data[0].get("id")
        print(f"  note: no {label} instance found — {label}-side deletion won't be wired.")
        return None
    radarr_arr = sonarr_arr = None
    if flavor == "mediaserver":
        rid = first_arr_id("/api/settings/radarr", "Radarr")
        radarr_arr = ("radarrSettingsId", rid) if rid is not None else None
        if args.shows:
            sid = first_arr_id("/api/settings/sonarr", "Sonarr")
            sonarr_arr = ("sonarrSettingsId", sid) if sid is not None else None

    # 4) Discord notifications — attach whatever is configured in Maintainerr (set it up first).
    notify_ids = []
    if not args.no_notify:
        s, cfgs = _req(f"{base}/api/notifications/configurations")
        notify_ids = [c["id"] for c in cfgs if isinstance(c, dict) and "id" in c] if isinstance(cfgs, list) else []
        if not notify_ids:
            die("no Maintainerr notification is configured, so there'd be nothing to review with.\n"
                "  Set one up first: Maintainerr UI -> Settings -> Notifications -> add a Discord webhook,\n"
                "  tick the events 'Media added to collection' AND 'Media about to be handled', save.\n"
                "  Then re-run this. (Or pass --no-notify to create the groups without Discord.)")
        print(f"attaching {len(notify_ids)} notification config(s): {notify_ids}\n")

    # 5) Existing groups — skip by name (idempotent).
    st, existing = _req(f"{base}/api/rules")
    existing_names = set()
    if st == 200 and isinstance(existing, list):
        for g in existing:
            n = (g.get("name") or (g.get("ruleGroup") or {}).get("name"))
            if n:
                existing_names.add(n)

    planned = []

    def add_pair(lib, props, min_mb, is_show):
        base_rules = common_rules(props, args.days, min_mb, args.keep_tag)
        if is_show:
            base_rules.append(boolean(0, RULE_OP_AND, POSS_EQUALS, props["ended"], True))  # ended series only
        arr = sonarr_arr if is_show else radarr_arr
        kind = "shows" if is_show else "movies"
        # Clear group — recent (released on/after cutoff): auto-delete with grace.
        clear_name = f"Clear — {lib['title']} (big unwatched {kind}, under {args.old_years}yr)"
        if clear_name not in existing_names:
            rules = base_rules + [abs_date(0, RULE_OP_AND, POSS_AFTER, props["release"], cutoff)]
            planned.append(build_group(
                clear_name,
                f"Auto-delete: {kind} in '{lib['title']}' over {min_mb/1024:.0f}GB, added >{args.days}d ago, "
                f"not watched in {args.days}d, released after {cutoff}, not tagged '{args.keep_tag}'. "
                f"{args.grace}-day grace. Tag '{args.keep_tag}' or exclude in Maintainerr to protect.",
                lib, flavor, rules, arr, ARRACTION_DELETE, args.grace, notify_ids))
        else:
            print(f"skip (exists): {clear_name}")
        # Review group — old (released before cutoff): never auto-deletes, just raised in Discord.
        review_name = f"Review — {lib['title']} (big unwatched {kind}, {args.old_years}yr+)"
        if review_name not in existing_names:
            rules = base_rules + [abs_date(0, RULE_OP_AND, POSS_BEFORE, props["release"], cutoff)]
            planned.append(build_group(
                review_name,
                f"REVIEW ONLY (never auto-deletes): old {kind} in '{lib['title']}' over {min_mb/1024:.0f}GB, "
                f"added >{args.days}d ago, not watched in {args.days}d, released before {cutoff}. These may be "
                f"hard to re-get — tag '{args.keep_tag}' to keep, or delete by hand in Maintainerr.",
                lib, flavor, rules, arr, ARRACTION_DO_NOTHING, None, notify_ids))
        else:
            print(f"skip (exists): {review_name}")

    for lib in movie_libs:
        add_pair(lib, movie_props, int(args.min_size_gb * 1024), is_show=False)
    if args.shows:
        for lib in show_libs:
            add_pair(lib, show_props, int(args.show_min_size_gb * 1024), is_show=True)

    if not planned:
        print("\nNothing to create (all target groups already exist). Done.")
        return

    print(f"\n{'Creating' if args.apply else 'Would create'} {len(planned)} rule group(s):\n")
    created = 0
    for g in planned:
        print(f"  • {g['name']}")
        print("    " + json.dumps(g, separators=(",", ":")))
        if args.apply:
            s, resp = _req(f"{base}/api/rules", method="POST", body=g)
            if s in (200, 201) and isinstance(resp, dict) and resp.get("code") == 1:
                created += 1
                print(f"    -> HTTP {s} OK")
            elif s in (200, 201) and resp is None:
                print(f"    -> HTTP {s} FAILED (empty body = server-side create error). Check: "
                      "pct exec 210 -- docker logs media-pipeline-maintainerr-1 --tail 15")
            else:
                print(f"    -> HTTP {s} FAILED: {str(resp)[:300]}")
        print()

    if not args.apply:
        print("DRY-RUN — nothing was created. Re-run with --apply to create these groups.")
    elif created:
        print(f"Created {created} group(s). Nothing is deleted yet — each group must be run (manually or by\n"
              "its schedule) to populate. Discord then posts candidates; the 'Clear' groups delete after the\n"
              f"grace window, the 'Review' groups never auto-delete. Protect a title: tag '{args.keep_tag}' in\n"
              "Radarr/Sonarr, or click exclude in Maintainerr.")
    else:
        print("No groups were created — see the FAILED line(s) above.")


if __name__ == "__main__":
    main()
