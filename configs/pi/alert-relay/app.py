#!/usr/bin/env python3
# alert-relay — sits between Alertmanager and Discord so embeds can be coloured by SEVERITY
# (Alertmanager's native Discord notifier only does firing=red / resolved=green). Posts ONE embed
# per alert: critical=red, warning=amber, resolved=green, with the same Impact/What/Fix/Where layout.
# Pure stdlib (no pip); reads the Discord webhook URL from the same gitignored file Alertmanager uses.
import json, os, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

WEBHOOK_FILE = os.environ.get("DISCORD_WEBHOOK_FILE", "/etc/alertmanager/discord-webhook-url")
PORT = int(os.environ.get("PORT", "9095"))

RED, AMBER, GREEN = 0xC0392B, 0xE67E22, 0x2ECC71   # critical / warning / resolved


def webhook_url():
    try:
        return open(WEBHOOK_FILE).read().strip()
    except Exception:
        return ""


def post_discord(url, embed):
    data = json.dumps({"embeds": [embed]}).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=10).read()
    except Exception as e:
        print("discord post failed:", e, flush=True)


def build_embed(alert):
    a = alert.get("annotations", {}) or {}
    l = alert.get("labels", {}) or {}
    status = alert.get("status", "firing")
    sev = l.get("severity", "warning")
    name = l.get("alertname", "alert")
    inst = l.get("instance", "")
    dev = l.get("device", "")

    if status == "resolved":
        color, head = GREEN, "✅ RESOLVED"
    elif sev == "critical":
        color, head = RED, "\U0001F534 CRITICAL"
    else:
        color, head = AMBER, "\U0001F7E7 WARNING"

    title = f"{head} — {name}" + (f" @ {inst}" if inst else "")
    tag = (f" · `{inst}`" if inst else "") + (f" · `{dev}`" if dev else "")
    if status == "resolved":
        desc = f"**{name}**{tag}\n✅ Resolved — {a.get('summary','')}"
    else:
        desc = (f"**{name}**{tag}\n_{a.get('summary','')}_\n\n"
                f"\U0001F4A5 **Impact** — {a.get('impact','')}\n"
                f"\U0001F50D **What** — {a.get('cause','')}\n"
                f"\U0001F6E0️ **Fix** — {a.get('fix','')}\n"
                f"\U0001F4CD **Where** — {a.get('where','')}")
    return {"title": title[:256], "description": desc[:4000], "color": color}


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        try:
            payload = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            payload = {}
        url = webhook_url()
        if url:
            for alert in payload.get("alerts", []):
                post_discord(url, build_embed(alert))
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")

    def do_GET(self):                       # health check
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")

    def log_message(self, *a):              # quiet
        pass


if __name__ == "__main__":
    print(f"alert-relay listening on :{PORT} (webhook file: {WEBHOOK_FILE})", flush=True)
    HTTPServer(("0.0.0.0", PORT), H).serve_forever()
