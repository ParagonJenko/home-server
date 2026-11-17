# Camera onboarding (Frigate NVR)

How to take a camera from "in the box" to "recording in Frigate and monitored in Grafana".
Frigate is already installed (LXC 111 on nuc2); what's missing per camera is **RTSP enabled, a
DHCP reservation, an AdGuard rewrite, and the shared RTSP credentials**. Do all four or the camera
records nothing.

The four cameras and their reserved IPs (from `network.md`):

| Camera | Reserved IP | Name |
|---|---|---|
| cam-living-room | `192.168.1.30` | cam-living-room.home.alexjenkinson.com |
| cam-kitchen | `192.168.1.31` | cam-kitchen.home.alexjenkinson.com |
| cam-bedroom | `192.168.1.32` | cam-bedroom.home.alexjenkinson.com |
| cam-basement | `192.168.1.33` | cam-basement.home.alexjenkinson.com |

Why by name, not IP: Frigate/go2rtc open each stream by hostname through the Pi resolver (R13), so
a camera stays portable and a lost reservation shows up as a clean DNS/RTSP failure, not silent data loss.

## 1. Enable RTSP on each camera (Eufy app)

Eufy cameras ship with local RTSP **off**. In the Eufy app, per camera:
- Device **Settings → General → (RTSP / NAS / ONVIF)** → turn **RTSP on**.
- Set a **username + password** — use the *same* pair for all four (that's what Frigate's one `.env` holds).
- Note the stream path it shows. Most Eufy models serve `/live0`; if a model differs, only that
  camera's `go2rtc` stream URL in `configs/frigate/config.yaml` changes.

Not every Eufy model exposes RTSP (some battery/wireless ones don't). A camera with no RTSP option
can't feed Frigate directly — it would need the HomeBase RTSP feature or a different model.

## 2. Discover each camera's MAC + current IP

From any box on the LAN (the Pi is fine):

```bash
cd ~/home-server && ./configs/frigate/find-cameras.sh
```

It scans the /24 for hosts with `:554` open and prints `IP  MAC`. Match each to its room (power one
camera at a time if you're unsure which is which).

## 3. Reserve .30–.33 on the router

In the router's DHCP settings, bind each camera's **MAC → its reserved IP** (.30 living-room,
.31 kitchen, .32 bedroom, .33 basement). These sit in the `.20`–`.39` reservation band, outside the
dynamic pool (`.40`–`.253`) on purpose, so the pool can never hand the address to something else.
Reboot each camera (or renew its lease) so it picks up the reserved address.

## 4. Record the MACs in network.md

Replace `TBD` in the four `cam-*` rows of `network.md` with the real MACs, then commit — this file is
the source of truth the rewrite tool reads:

```bash
# edit network.md, then:
git add network.md && git commit -m "net: record camera MACs" && git push
```

## 5. Push the AdGuard rewrites

The rewrite tool reads `network.md` and maps `cam-*` → `.30–.33`:

```bash
# on the Pi
cd ~/home-server
python3 configs/pi/adguard-rewrites.py            # dry run — shows what it will add
python3 configs/pi/adguard-rewrites.py --apply    # push
python3 configs/pi/adguard-rewrites.py --check     # exits non-zero if anything's wrong
```

## 6. Give Frigate the RTSP credentials

Frigate reads one `.env` (gitignored — never commit real creds, R21):

```bash
# on nuc2, inside LXC 111
pct enter 111
cd /opt/frigate
cp .env.example .env    # if not already present
# edit .env: FRIGATE_RTSP_USER / FRIGATE_RTSP_PASSWORD = the pair set in step 1
docker compose up -d    # recreate so go2rtc picks up the creds
```

## 7. Verify

```bash
# names resolve (run from inside LXC 111 — it must resolve via Pi DNS):
for c in living-room kitchen bedroom basement; do getent hosts cam-$c.home.alexjenkinson.com; done

# RTSP ports reachable:
for ip in 30 31 32 33; do nc -z -w2 192.168.1.$ip 554 && echo ".$ip :554 open"; done

# Frigate pulling streams: open https://frigate.home.alexjenkinson.com — each camera shows live.
./configs/frigate/verify-frigate.sh

# monitoring: Prometheus → Status → Targets, blackbox-cameras UP; Grafana "Network & Uptime" camera tiles green.
```

The `CameraDown` alert (RTSP `:554` unreachable for 10m) fires to Discord if a camera drops its stream.

## Troubleshooting

- **Stream down, name won't resolve from inside LXC 111:** the container's resolver isn't the Pi, or
  the rewrite didn't push. `getent hosts cam-*...` inside 111; re-run `adguard-rewrites.py --apply`.
- **Name resolves but no video:** RTSP path isn't `/live0` for that model — fix only that camera's
  `go2rtc` stream URL in `config.yaml`; or the creds in `.env` are wrong; or RTSP got toggled off.
- **Camera tile DOWN in Grafana but video is fine:** the blackbox probe uses `tcp_connect` on `:554`
  by name — check the camera's rewrite and that it's actually at its reserved IP (`ip neigh`).
- **Wrong camera at an IP:** the DHCP reservation MAC is mismatched — re-run `find-cameras.sh` and
  recheck which MAC is which room.
