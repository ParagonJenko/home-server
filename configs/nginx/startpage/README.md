# Start page (self-hosted new-tab dashboard)

A static page of links to the home-server services and ideaSquared tools, served by Nginx at
**`https://start.home.alexjenkinson.com`**. Dark-first, with a live filter (`/` focuses it, Enter
opens the top match, Esc clears). Edit `index.html` to add/remove links — it's plain HTML, one
`<a class="card">` per link.

## Deploy (on the Nginx proxy, LXC 240)

The `start.home` server block is in `homelab.conf`, so BOTH the config and the static files need to
land on the proxy — copying only `index.html` leaves Nginx with no `start.home` block, and the
request falls through to the first HTTPS site (Plex).

1. **Deploy the Nginx config** (this carries the new `start.home` server block). From `root@nuc1`
   (Nginx is LXC 240 on nuc1):
   ```bash
   pct push 240 configs/nginx/homelab.conf /etc/nginx/conf.d/homelab.conf
   pct exec 240 -- sed -i 's/{{PI_IP}}/192.168.1.4/' /etc/nginx/conf.d/homelab.conf   # fill the resolver
   pct exec 240 -- nginx -t && pct exec 240 -- nginx -s reload
   ```

2. **Copy the static files** to where the server block's `root` points:
   ```bash
   pct exec 240 -- mkdir -p /etc/nginx/startpage
   pct push 240 configs/nginx/startpage/index.html /etc/nginx/startpage/index.html
   ```

3. **DNS**: `start.home.alexjenkinson.com` is in group 1 of `network.md` (front names → Nginx `.20`).
   Re-push AdGuard rewrites so it resolves:
   ```bash
   python3 configs/pi/adguard-rewrites.py        # dry run
   python3 configs/pi/adguard-rewrites.py --apply
   ```

3. **Reload Nginx** on the proxy:
   ```bash
   pct exec 240 -- nginx -t && pct exec 240 -- nginx -s reload
   ```

4. Visit `https://start.home.alexjenkinson.com`. The `*.home.alexjenkinson.com` wildcard cert already
   covers it, so no new certificate.

## Make it your Chrome new tab

Chrome blocks pages from overriding the new-tab page directly, so use a tiny extension (one-time):

1. Install **"Custom New Tab URL"** (or "New Tab Redirect") from the Chrome Web Store.
2. Set the new-tab URL to `https://start.home.alexjenkinson.com`.

That's it — every new tab now opens the start page. (Off the LAN the `.home` links won't resolve; it's
a home dashboard. Reach it via Tailscale if you want it remotely.)
