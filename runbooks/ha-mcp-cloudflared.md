# Claude ↔ Home Assistant over MCP (Cloudflare tunnel)

Lets Claude **read and control Home Assistant directly** — list entities, deploy dashboards, rename
things, check camera state — instead of pasting `/api/states` dumps. It's the HA equivalent of a
connector: HA runs an MCP server, a Cloudflare tunnel publishes it, and claude.ai adds it as a custom
connector.

```
Claude (Anthropic cloud) → https://ha-mcp.alexjenkinson.com/private_<secret>
   → Cloudflare edge → cloudflared (LXC 112, nuc2) → HA-MCP :9584 (HA VM 910)
```

**This is NOT the Frigate MQTT path.** MQTT/Mosquitto carry Frigate's detection events into HA
(see `eufy-ha.md`). This is HA's *own* API exposed over MCP — unrelated, different port (`:9584`).

## Components

| Piece | Where | Notes |
|---|---|---|
| **HA-MCP integration** | HA VM 910 | `homeassistant-ai/ha-mcp` — runs the MCP server in-process, serves `:9584` |
| **cloudflared** | LXC 112, nuc2 | `configs/lxc/cloudflared.sh` — outbound-only tunnel, no inbound ports |
| **Cloudflare named tunnel** | Cloudflare Zero Trust | public hostname `ha-mcp.alexjenkinson.com` → `192.168.1.25:9584` |
| **Custom connector** | claude.ai → Settings → Connectors | URL = tunnel + `/private_<secret>`, auth **None** |

## Build

### 1. HA-MCP integration (in HA)
1. Install **HA-MCP** from **Settings → Marketplace** (2026.11+; HACS on 2026.10 and older — see the
   HACS→Marketplace note below).
2. Settings → Devices & Services → Add Integration → **HA-MCP Server** → supply a long-lived token
   (a dedicated admin account is cleaner than your own).
3. In the integration's **Configure** screen: enable **local network access** (that's the `:9584`
   endpoint the tunnel targets) and set auth to the **secret-URL** mode — **not OAuth** (see gotcha).
   Copy the `/private_<secret>` path it shows; that path *is* the credential.

### 2. cloudflared LXC (nuc2)
`configs/lxc/cloudflared.sh` builds CT 112 (unprivileged, outbound-only) and installs the cloudflared
static binary. The target + optional tunnel token live in the gitignored `configs/cloudflared/.env`
(boxes pull only — the token is set on-box, never committed). `run.sh` picks the mode:
- **quick tunnel** (no token) → instant `https://<random>.trycloudflare.com`, **rotates on every
  restart** — testing only.
- **named tunnel** (token set) → stable hostname. This is what we run.

### 3. Cloudflare named tunnel (Zero Trust)
1. **one.dash.cloudflare.com** → **Networks → Tunnels → Create a tunnel** → type **Cloudflared** →
   name `ha-mcp` → Save.
2. Copy the **token** (the long `eyJ…` blob — not the tunnel ID/name).
3. **Add a route → Published application**: subdomain `ha-mcp`, domain `alexjenkinson.com`, Type
   **HTTP**, URL `192.168.1.25:9584`. Saving auto-creates the proxied DNS CNAME.
4. On nuc2, put the token in `.env` and restart (no script re-run needed):
   ```bash
   cd ~/home-server
   read -rsp 'CF tunnel token: ' TOK; echo
   grep -v '^CLOUDFLARED_TUNNEL_TOKEN=' configs/cloudflared/.env > /tmp/cfenv 2>/dev/null || true
   mv /tmp/cfenv configs/cloudflared/.env 2>/dev/null || true
   printf 'CLOUDFLARED_TUNNEL_TOKEN=%s\n' "$TOK" >> configs/cloudflared/.env
   pct push 112 configs/cloudflared/.env /opt/cloudflared/.env
   pct exec 112 -- systemctl restart cloudflared
   ```
   (Use `read`, not `sed`, to paste the token — base64 `+/=` chars break a sed one-liner.)
5. Verify: `pct exec 112 -- journalctl -u cloudflared --no-pager | tail` shows `Registered tunnel
   connection`, and from anywhere:
   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" --resolve ha-mcp.alexjenkinson.com:443:172.67.209.51 https://ha-mcp.alexjenkinson.com/
   ```
   → **404** (HA-MCP's root responding = tunnel→origin works; the MCP lives at the `/private_` path).

### 4. Custom connector (claude.ai)
Settings → Connectors → **Add custom connector** → URL `https://ha-mcp.alexjenkinson.com/private_<path>`,
auth **None** → Connect. In a Claude Code / Cowork session, `RefreshMcpTools` then surfaces the
`mcp__Home_Assistant_MCP__*` tools.

## Gotchas

- **OAuth mode doesn't work over a tunnel like this.** Claude tries dynamic client registration against
  HA-MCP's OAuth endpoints; over a quick tunnel (and a path-only named route) those aren't reachable, so
  you get `Couldn't register…` then `Couldn't reach…`. Use the **secret-URL** auth mode — the
  unguessable `/private_` path + HTTPS is the security.
- **Quick-tunnel URL churn.** Every `cloudflared` restart (including re-running `cloudflared.sh`) gives a
  new `trycloudflare.com` URL, breaking the connector. The named tunnel fixes this permanently.
- **AdGuard split-horizon.** `ha-mcp.alexjenkinson.com` is a *public* Cloudflare record; your internal
  AdGuard doesn't resolve your own domain's public subdomains (it returned no answer in testing). This
  does **not** affect Claude — Anthropic's cloud uses public DNS, which resolves fine. It only means
  *internal* `curl` tests fail; test with `--resolve` to a Cloudflare IP. For internal access, add an
  AdGuard rewrite `ha-mcp.alexjenkinson.com → 192.168.1.25`.
- **The secret is the `/private_<path>`.** Keep it out of git and out of chat. It lives only in HA and
  in the connector. Rotating it (regenerate in HA-MCP Configure) invalidates old connectors.
- **Token is gitignored, box-local.** `configs/cloudflared/.env` holds `CLOUDFLARED_TUNNEL_TOKEN`; boxes
  pull only, so it's set on-box and never committed (R21).

## What it unlocks

With the connector live, Claude can enumerate entities, read live state, and **deploy dashboards
straight to HA** (`ha_config_set_dashboard`) — that's how `configs/homeassistant/dashboards/home.json`
is pushed, instead of pasting YAML into the raw editor. Also entity/area edits, camera snapshots, and
service calls — all with per-write approval.
