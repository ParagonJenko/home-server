#!/usr/bin/env python3
"""maintainerr-seed-rules.py — seed starter watch-based cleanup rule groups in Maintainerr.

Maintainerr's rule format addresses every property as a numeric [application, property]
pair whose IDs can drift between versions, so this script never hardcodes them: it reads
GET /api/rules/constants at runtime and resolves Plex properties BY NAME (addDate,
lastViewedAt, sw_lastWatched). Plex library IDs are discovered from the live instance too.

It also adapts to BOTH Maintainerr API generations:
  * 2.x (current stable, e.g. 2.19): libraries at /api/plex/libraries (id field 'key'),
    dataType is the numeric EPlexDataType (movie=1, show=2), one Radarr/Sonarr assumed.
  * newer 'main' (media-server abstraction): /api/media-server/libraries (id field 'id'),
    dataType is the string 'movie'/'show', with radarrSettingsId/sonarrSettingsId.

What it creates (conservative on purpose), one group per movie library:
    delete when the film was ADDED over N days ago AND last watched over N days ago (films
    watched in the last N days are excluded; see build_group for how never-watched films land
    under Maintainerr's evaluation). The "added over N days ago" half is the safety net: a
    film you added last week is never a match. N defaults to 90.
  --shows adds a show-library group: added >N days ago AND no episode watched in N days
    (180d) AND the series has ENDED in Sonarr — so a still-airing show you're between seasons
    on is never matched, only finished shows you've abandoned.

Two layers of safety before anything is deleted:
  1. DRY-RUN by default. It prints the exact payloads and changes nothing. Add --apply to POST.
  2. Even applied, Maintainerr does NOT run a group on creation, and the collection holds a
     matched item for --grace days (default 7) before the delete fires. So you get a preview
     in the UI and a grace window. Review in the UI, then run the group when you're happy.

Idempotent: a group whose name already exists is skipped, so re-running is safe.

Run it from anywhere that can reach Maintainerr's API (the nuc1 host, or inside LXC 210 with
--url http://localhost:6246). Plex + Radarr/Sonarr must already be connected in the UI first.

  Preview:  ./maintainerr-seed-rules.py
  Apply:    ./maintainerr-seed-rules.py --apply
  + shows:  ./maintainerr-seed-rules.py --apply --shows
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

DEFAULT_URL = os.environ.get("MAINTAINERR_URL", "http://media-pipeline.home.alexjenkinson.com:6246")
DAY = 86400

# Enum values from Maintainerr's rule constants (stable/append-only across 2.x and main).
RULE_OP_AND = 0         # RuleOperators.AND
POSS_EQUALS = 2         # RulePossibility.EQUALS
POSS_BEFORE = 5         # RulePossibility.BEFORE  — date is further in the past than the value
RULETYPE_NUMBER = 0     # customVal.ruleTypeId for a relative duration (value = seconds, as string)
RULETYPE_BOOL = 3       # customVal.ruleTypeId for a boolean ("1"/"0")
ARRACTION_DELETE = 0    # ServarrAction.DELETE
EPLEX_MOVIES = 1        # EPlexDataType.MOVIES  (2.x numeric dataType)
EPLEX_SHOWS = 2         # EPlexDataType.SHOWS


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


def date_rule(section, operator, action, firstval, seconds=None):
    r = {"operator": operator, "action": action, "firstVal": firstval, "section": section}
    if seconds is not None:
        r["customVal"] = {"ruleTypeId": RULETYPE_NUMBER, "value": str(seconds)}
    return r


def bool_rule(section, operator, action, firstval, truthy=True):
    return {"operator": operator, "action": action, "firstVal": firstval, "section": section,
            "customVal": {"ruleTypeId": RULETYPE_BOOL, "value": "1" if truthy else "0"}}


def build_group(name, desc, library, flavor, added_prop, watched_prop, days, grace, arr, extra_rules=None):
    """added >N days ago AND last watched >N days ago.

    Two BEFORE rules AND'd together. Encoded this way on purpose (not NOT_EXISTS):
    Maintainerr evaluates an AND rule by *removing* items that explicitly fail it, and skips
    the rule entirely for an item whose value is missing. So the first rule seeds the set with
    everything added >N days ago, and the second removes only films watched within the last N
    days — a never-watched film (no last-view date) is skipped, not removed, so it stays in.
    Net: 'old and not watched recently', which is the safe cleanup target. Review in the UI to
    confirm how your library's never-watched items land before trusting it.
    """
    secs = days * DAY
    rules = [
        date_rule(0, None, POSS_BEFORE, added_prop, secs),         # added > N days ago
        date_rule(0, RULE_OP_AND, POSS_BEFORE, watched_prop, secs),  # AND not watched in N days
    ]
    rules += extra_rules or []                                      # e.g. shows: AND Sonarr ended
    # dataType + libraryId differ between the two API generations.
    if flavor == "plex":
        data_type = EPLEX_MOVIES if library["type"] == "movie" else EPLEX_SHOWS
        try:
            library_id = int(library["id"])      # RulesDto.libraryId is numeric in 2.x
        except (TypeError, ValueError):
            library_id = library["id"]
    else:
        data_type = library["type"]              # 'movie' | 'show'
        library_id = str(library["id"])
    group = {
        "libraryId": library_id,
        "name": name,
        "description": desc,
        "isActive": True,
        "useRules": True,
        "arrAction": ARRACTION_DELETE,
        "dataType": data_type,
        "collection": {
            "deleteAfterDays": grace,            # grace window before deletion fires
            "keepLogsForMonths": 6,
            "visibleOnHome": False,
        },
        "rules": rules,
        # MUST be an empty list, not omitted: createOrUpdateGroup does
        # `.add(notifications?.map(...))`, and on undefined that becomes `.add(undefined)` which
        # inserts a null notificationId and trips a NOT NULL constraint, failing the whole group.
        "notifications": [],
    }
    # The newer API ties a group to a specific Radarr/Sonarr instance; 2.x assumes the single
    # configured one, so only send the settings id on the media-server flavor.
    if arr is not None:
        group[arr[0]] = arr[1]
    return group


def main():
    ap = argparse.ArgumentParser(description="Seed starter watch-based cleanup rules in Maintainerr.")
    ap.add_argument("--url", default=DEFAULT_URL, help=f"Maintainerr base URL (default {DEFAULT_URL})")
    ap.add_argument("--apply", action="store_true", help="actually create the groups (default: preview only)")
    ap.add_argument("--shows", action="store_true", help="also seed a show-library rule (off by default)")
    ap.add_argument("--days", type=int, default=90, help="movie unwatched window in days (default 90)")
    ap.add_argument("--show-days", type=int, default=180, help="show unwatched window in days (default 180)")
    ap.add_argument("--grace", type=int, default=7, help="deleteAfterDays grace before deletion (default 7)")
    args = ap.parse_args()
    base = args.url.rstrip("/")

    print(f"Maintainerr: {base}   mode: {'APPLY' if args.apply else 'DRY-RUN (no changes)'}\n")

    # 1) Libraries (also the "is Plex connected?" check) + which API generation we're on.
    libs, flavor = get_libraries(base)
    if not libs:
        die("Maintainerr returned no movie/show libraries — finish connecting Plex in the UI, then re-run.")
    movie_libs = [l for l in libs if l["type"] == "movie"]
    show_libs = [l for l in libs if l["type"] == "show"]
    print(f"API: {flavor}   libraries: "
          + ", ".join(f"{l['title']} ({l['type']}, id={l['id']})" for l in libs) + "\n")

    # 2) Rule constants — resolve property IDs by name (version-robust).
    st, constants = _req(f"{base}/api/rules/constants")
    if st != 200 or not isinstance(constants, dict):
        die(f"could not read /api/rules/constants (HTTP {st}).")
    plex_added = resolve_prop(constants, "Plex", "addDate")
    plex_lastviewed = resolve_prop(constants, "Plex", "lastViewedAt")
    plex_sw_lastwatched = resolve_prop(constants, "Plex", "sw_lastWatched")
    sonarr_ended = resolve_prop(constants, "Sonarr", "ended") if args.shows else None

    # 3) Arr instance IDs — only the newer API ties a group to one; 2.x uses the single config.
    def first_arr_id(path, label):
        s, data = _req(f"{base}{path}")
        if s == 200 and isinstance(data, list) and data:
            if len(data) > 1:
                print(f"  note: {len(data)} {label} instances; using the first (id={data[0].get('id')}).")
            return data[0].get("id")
        print(f"  note: no {label} instance found — {label}-side deletion won't be wired "
              f"(Plex + disk delete still works).")
        return None
    radarr_arr = sonarr_arr = None
    if flavor == "mediaserver":
        rid = first_arr_id("/api/settings/radarr", "Radarr")
        radarr_arr = ("radarrSettingsId", rid) if rid is not None else None
        if args.shows:
            sid = first_arr_id("/api/settings/sonarr", "Sonarr")
            sonarr_arr = ("sonarrSettingsId", sid) if sid is not None else None
        print()

    # 4) Existing groups — skip by name (idempotent).
    st, existing = _req(f"{base}/api/rules")
    existing_names = set()
    if st == 200 and isinstance(existing, list):
        for g in existing:
            n = (g.get("name") or (g.get("ruleGroup") or {}).get("name"))
            if n:
                existing_names.add(n)

    planned = []
    for lib in movie_libs:
        name = f"Unwatched movies — {lib['title']} ({args.days}d)"
        if name in existing_names:
            print(f"skip (exists): {name}")
            continue
        planned.append(build_group(
            name,
            f"Delete movies in '{lib['title']}' added over {args.days} days ago and not watched "
            f"in the last {args.days} days. {args.grace}-day grace before removal.",
            lib, flavor, plex_added, plex_lastviewed, args.days, args.grace, radarr_arr))
    if args.shows:
        for lib in show_libs:
            name = f"Unwatched shows — {lib['title']} ({args.show_days}d)"
            if name in existing_names:
                print(f"skip (exists): {name}")
                continue
            planned.append(build_group(
                name,
                f"Delete ENDED shows in '{lib['title']}' added over {args.show_days} days ago with no "
                f"episode watched in {args.show_days} days. Still-airing series are never matched. "
                f"{args.grace}-day grace before removal.",
                lib, flavor, plex_added, plex_sw_lastwatched, args.show_days, args.grace, sonarr_arr,
                # AND Sonarr 'ended' == true: only finished series, never one still airing.
                extra_rules=[bool_rule(0, RULE_OP_AND, POSS_EQUALS, sonarr_ended, truthy=True)]))

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
        print(f"Created {created} group(s). Nothing is deleted yet: open each group in the Maintainerr UI,\n"
              "review the matched items, then run the group. Matches then sit in the collection for the\n"
              "grace window before removal.")
    else:
        print("No groups were created — see the FAILED line(s) above.")


if __name__ == "__main__":
    main()
