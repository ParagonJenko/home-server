#!/usr/bin/env python3
"""arr-setup.py — wire the Arr stack over their APIs (root folders, qBittorrent
client + category on Sonarr/Radarr, Prowlarr sync, FlareSolverr proxy).

Dry-run by default; --apply writes. Idempotent, and asks each app for its own
schema rather than hardcoding field names, so it survives Arr releases.
Indexers stay manual (they need your accounts). Quality profiles are Recyclarr's job.

Reads API keys from .env (gitignored). This is a scaffold — implement against the
Sonarr/Radarr/Prowlarr v3 APIs.
"""
import argparse, os

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="write changes (default: dry run)")
    args = ap.parse_args()
    # TODO: load .env; for each app GET /api/v3/.../schema then POST the config idempotently.
    print("arr-setup:", "APPLY" if args.apply else "DRY RUN", "— TODO implement (see docstring).")

if __name__ == "__main__":
    main()
