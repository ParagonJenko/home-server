# Start page (self-hosted new-tab dashboard)

A static page of links to the home-server services and ideaSquared tools, served by Nginx at
**`https://start.home.alexjenkinson.com`**. Dark-first, with a live filter (`/` focuses it, Enter
opens the top match, Esc clears). Edit `index.html` to add/remove links — it's plain HTML, one
`<a class="card">` per link.

## Deploy (on the Nginx proxy, LXC 240)

The `start.home` server block is already in `homelab.conf`. You just need the static files on the box
and DNS pointing at Nginx.

1. **Copy the files** to where the server block's `root` points:
   ```bash
   # from a machine with the repo, e.g. the Proxmox host:
   pct exec 240 -- mkdir -p /etc/nginx/startpage
   # then copy index.html in (adjust source path to your clone):
   pct push 240 configs/nginx/startpage/index.html /etc/nginx/startpage/index.html
   ```
   (Or however you already sync `homelab.conf` onto the proxy — same destination box.)

2. **DNS**: `start.home.alexjenkinson.com` is in group 1 of `network.md` (front names → Nginx `.20`).
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
