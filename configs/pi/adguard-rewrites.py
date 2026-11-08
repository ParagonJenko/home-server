#!/usr/bin/env python3
"""adguard-rewrites.py — read the address register out of ../../network.md and push
every DNS rewrite over AdGuard's API (18+ entries typed into a web form is how one
ends up wrong). Three groups: front names -> Nginx, backend names -> container,
hosts/cameras -> their own IP.

  --apply   write (default is dry run)
  --check   fail if a name documented in network.md isn't being pushed (run on a schedule
            so the resolver can't quietly drift from the doc)

Scaffold — implement against the AdGuard Home control API (/control/rewrite/*).
AdGuard admin creds come from the environment or a gitignored file, never committed.
"""
import argparse

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    # TODO: parse ../../network.md rewrite groups; diff against /control/rewrite/list; apply/check.
    print("adguard-rewrites:", "CHECK" if args.check else ("APPLY" if args.apply else "DRY RUN"), "— TODO.")

if __name__ == "__main__":
    main()
