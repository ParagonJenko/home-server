#!/usr/bin/env python3
"""maintainerr-exporter — a tiny Prometheus exporter for Maintainerr (which has no native metrics).

Maintainerr exposes a REST API; this scrapes it on each /metrics scrape and emits the cleanup
backlog as Prometheus text. Stdlib only (urllib + http.server) so it runs on python:3.12-alpine
with no pip, same as the alert-relay.

Metrics:
  maintainerr_up                               1 if the API answered, else 0
  maintainerr_rule_groups                      number of rule groups (GET /api/rules/count)
  maintainerr_collections                      number of collections
  maintainerr_collection_items{collection,active}   items currently in each collection — i.e. the
                                               deletion/review candidates pending in each Clear/Review group
  maintainerr_scrape_duration_seconds          how long the scrape took

Env:
  MAINTAINERR_URL   default http://media-pipeline.home.alexjenkinson.com:6246
  LISTEN_PORT       default 9116
"""
import json
import os
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

BASE = os.environ.get("MAINTAINERR_URL", "http://media-pipeline.home.alexjenkinson.com:6246").rstrip("/")
PORT = int(os.environ.get("LISTEN_PORT", "9116"))


def _get(path, timeout=10):
    with urllib.request.urlopen(f"{BASE}{path}", timeout=timeout) as r:
        raw = r.read().decode()
        return json.loads(raw) if raw.strip() else None


def _as_int(v):
    """Maintainerr endpoints return a bare number or a small object; pull an int out of either."""
    if isinstance(v, bool):
        return int(v)
    if isinstance(v, (int, float)):
        return int(v)
    if isinstance(v, dict):
        for k in ("count", "value", "total", "result"):
            if isinstance(v.get(k), (int, float)):
                return int(v[k])
    return 0


def _esc(s):
    return str(s).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def collect():
    lines = [
        "# HELP maintainerr_up 1 if the Maintainerr API answered.",
        "# TYPE maintainerr_up gauge",
        "# HELP maintainerr_rule_groups Number of rule groups.",
        "# TYPE maintainerr_rule_groups gauge",
        "# HELP maintainerr_collections Number of collections.",
        "# TYPE maintainerr_collections gauge",
        "# HELP maintainerr_collection_items Items currently in each collection (pending candidates).",
        "# TYPE maintainerr_collection_items gauge",
        "# HELP maintainerr_scrape_duration_seconds Duration of the Maintainerr scrape.",
        "# TYPE maintainerr_scrape_duration_seconds gauge",
    ]
    t0 = time.time()
    up = 1
    try:
        groups = _as_int(_get("/api/rules/count"))
        cols = _get("/api/collections")
        cols = cols if isinstance(cols, list) else []
        lines.append(f"maintainerr_rule_groups {groups}")
        lines.append(f"maintainerr_collections {len(cols)}")
        for c in cols:
            cid = c.get("id")
            title = c.get("title", f"collection-{cid}")
            active = "true" if c.get("isActive") else "false"
            try:
                n = _as_int(_get(f"/api/collections/media/count?collectionId={cid}"))
            except Exception:
                n = 0
            lines.append(f'maintainerr_collection_items{{collection="{_esc(title)}",active="{active}"}} {n}')
    except Exception as e:
        up = 0
        print(f"[maintainerr-exporter] scrape failed: {e}", flush=True)
    lines.append(f"maintainerr_up {up}")
    lines.append(f"maintainerr_scrape_duration_seconds {time.time() - t0:.4f}")
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?")[0] != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        body = collect().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass  # quiet


if __name__ == "__main__":
    print(f"[maintainerr-exporter] serving :{PORT}/metrics, source {BASE}", flush=True)
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
