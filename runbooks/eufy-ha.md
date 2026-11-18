# Eufy (cameras + doorbell + RoboVac) and Frigate in Home Assistant

## Architecture: camera → Frigate → HA (one hub)

The clean design routes every camera that can stream through **Frigate**, and HA gets the cameras +
detections from Frigate via the Frigate integration — not a separate per-camera integration:

```
camera  →  go2rtc (restream)  →  Frigate (detect + record)  →  Frigate HA integration  →  HA
```

**go2rtc is built into Frigate.** Its whole job is to take a camera's stream — or Eufy's awkward
on-demand P2P stream — and turn it into one stable stream that Frigate consumes and re-shares.
(That's why go2rtc was needed before: it's the restreaming bridge.) HA then gets `camera.<name>`,
`binary_sensor.<name>_motion` / `_person`, snapshots and clips, all from Frigate.

**The one hard constraint is a *continuous* stream:**

The cameras here are all Eufy (living-room + the others at `.30`–`.33`). Eufy support for a
continuous stream is **per-model**, so the model decides the path:

| Camera type | Continuous stream? | Path |
|---|---|---|
| Wired Eufy with in-app **RTSP** (Indoor Cam, Floodlight, wired SoloCam, wired doorbell) | yes — native RTSP | `rtsp://…` straight into Frigate — ideal |
| Wired Eufy without RTSP, on a HomeBase | maybe — go2rtc holds the eufy-security-ws stream open | camera → eufy-security-ws → go2rtc → Frigate |
| **Battery** Eufy (eufyCam 2/3/S3, battery SoloCam/doorbell) | **no — sleeps to save battery** | `eufy_security` integration on-demand only, NOT Frigate |
| Eufy RoboVac | n/a | `bmccluskey/robovac` HACS integration → `vacuum.*` |

So Frigate is the hub for any Eufy cam that streams continuously — **wired models, ideally ones with
the in-app RTSP toggle** (Settings → the cam → *RTSP*). Battery cams physically can't do 24/7
detection; for those `eufy_security` on-demand view + Eufy-side motion is the best achievable.
**The camera model is what decides this** — get the models before wiring Frigate.

## This home's split (decided — verified working 2026-11-18)

- **4 indoor cams — wired; RTSP is enabled *by* the eufy_security integration → go2rtc (in Frigate) →
  Frigate & HA.** CORRECTION to the earlier assumption: these cams do **not** expose RTSP from the Eufy
  app. RTSP turns on when the **eufy-security-ws add-on + eufy_security integration** connect (Stage 1) —
  that's the piece that makes the cameras serve a stream. Once it's connected *and* `configs/frigate/.env`
  holds the RTSP creds, Frigate's built-in go2rtc pulls
  `rtsp://…@cam-<room>.home.alexjenkinson.com:554/live0` and the four Frigate camera entities flip from
  `unavailable` to `recording` on their own — HA gets them via the Frigate integration, no separate Eufy
  camera entities needed. (Verified by pulling a live snapshot over MCP the moment the add-on connected.)
- **Doorbell — battery → the same `eufy_security` integration** (Stage 1). Sleeps, so it can't go in
  Frigate; the integration gives the press event, on-demand view and motion.
- **RoboVac → `bmccluskey/robovac`** (Stage 2).

## Stage 1 — eufy-security-ws + the eufy_security integration (REQUIRED for the cameras AND doorbell)

This is what turns **RTSP on** for the wired cameras (so Frigate can pull them) **and** covers the
battery doorbell (press events, motion, on-demand view). Without it the cameras serve no stream and
Frigate's go2rtc has nothing to connect to — the four Frigate cams sit `unavailable`. The add-on is
`bropat/hassio-eufy-security-ws` (store slug `402f1039_eufy_security_ws`); it can be added + installed
from the HA-MCP connector (`ha_manage_app add_repository` then `install`) but must be **configured with
your Eufy account and started by you**.

**Prereq: make a SECONDARY Eufy account.** The integration holds a login session; if it uses your
main account you get logged out of the phone app constantly and hit 2FA churn. In the Eufy app
(main account) → add a guest/shared member, give it access to the HomeBase + devices, use THAT
account's email/password below.

1. **Add-on** — Settings → Add-ons → Store → ⋮ → Repositories → add
   `https://github.com/bropat/hassio-eufy-security-ws` → install **Eufy Security Add-on**. Configure:
   `username` (secondary account), `password`, `country: GB`, `trusted_device_name: homeassistant`.
   Start it. (It listens on `:3000`.)
2. **go2rtc / WebRTC** — already installed here (WebRTC Camera / `update.webrtc_camera`). Nothing to do.
3. **Integration** — **Settings → Marketplace** (2026.11+; HACS on older) → **Eufy Security** → install
   → restart HA. Settings → Devices & Services → Add Integration → **Eufy Security** → host `127.0.0.1`,
   port `3000`. First login throws a **captcha + MFA** challenge: enter the captcha characters and the
   emailed code **together in the same step** — the code expires in a couple of minutes, so fetch it
   right before submitting. Email-based 2FA works best here; an authenticator app is fiddlier.
4. In the Eufy app set **Streaming Quality + Codec to LOW** on each cam (P2P is bandwidth-heavy).
5. Entities appear as `camera.*`, plus `binary_sensor.*` (motion/person), `sensor.*` (battery), and
   doorbell events. **Re-run the `/api/states` dump and send it** — the dashboard Security tab is
   camera-ready and I'll drop the real cards in.

## Stage 2 — Eufy RoboVac into HA

RoboVacs are **not** part of eufy_security — they're local Tuya devices. Use **`damacus/robovac`**
(the maintained successor to `bmccluskey/robovac`), which is in the **Marketplace catalog** — no custom
repo. Installed here 2026-11-18 (v2.5.2) via HA-MCP (`ha_manage_hacs download`).

1. Settings → **Marketplace** → search **RoboVac** (`damacus/robovac`) → install → **restart HA** to load it.
2. Settings → Devices & Services → Add Integration → **RoboVac** → **log in with your Eufy account**
   (email + password). v2.x **auto-retrieves the device ID, local key and model from Eufy's API** — no
   manual Tuya key extraction. Check the model first: <https://damacus.github.io/robovac/supported-models/>.
3. You get a `vacuum.*` entity (start/stop/return/locate) + battery/status — wire it into a **Cleaning**
   card on the dashboard once the entity exists.

## Stage 3 — Frigate (LXC 111, nuc2) — the 4 indoor cams

`configs/frigate/config.yaml` is **already written** for the 4 wired indoor cams: each is a go2rtc
stream `rtsp://{FRIGATE_RTSP_USER}:{FRIGATE_RTSP_PASSWORD}@cam-<room>.home.alexjenkinson.com:554/live0`,
and Frigate detects+records off go2rtc on localhost. What's left is turning RTSP on and pointing DNS:

1. **RTSP is enabled by the eufy_security integration (Stage 1), NOT the Eufy app.** Once the add-on +
   integration connect, the cams serve RTSP on their LAN IP at `/live0`. The creds in
   `configs/frigate/.env` (`FRIGATE_RTSP_USER`/`PASSWORD`) must match what the cams use. If a cam's path
   isn't `/live0`, change only that camera's go2rtc URL. (In practice the four cams flipped from
   `unavailable` to `recording` on their own once the integration connected and the creds were already
   in `.env` — no per-cam toggling needed.)
2. **Credentials** → put `FRIGATE_RTSP_USER` + `FRIGATE_RTSP_PASSWORD` in `configs/frigate/.env`
   (gitignored). The config has no secrets.
3. **DNS** → each `cam-<room>.home.alexjenkinson.com` must resolve to the camera's IP from inside the
   Frigate container. Add a DHCP reservation per cam (they were found at `.30`–`.33`) + an AdGuard
   rewrite (Stage D). Check with `getent hosts cam-living-room.home.alexjenkinson.com`.
4. **Deploy** → `./configs/lxc/frigate.sh` (or push config + restart) then `./configs/frigate/verify-frigate.sh`.
5. **Names** → the config uses `cam-living-room/kitchen/bedroom/basement` as placeholders — rename to
   your actual rooms in both the `go2rtc:` and `cameras:` blocks (and the DNS names) so they match.

Tuning (later): detection runs on CPU by default — if the Frigate LXC has the iGPU passed through,
add an OpenVINO detector; otherwise a Coral. For 4 cams, set a sane `detect:` resolution.
RTSP-discovery mechanics: `cameras.md`.

## Stage 4 — Frigate into HA (the camera entities + detection)

**go2rtc is NOT a separate HA install** — it's inside Frigate; the Frigate integration is all HA
needs. **MQTT has TWO separate halves in HA — the broker add-on AND the MQTT integration — and you
need both.** Four pieces:

1. **MQTT broker (add-on)** — HA → Settings → Add-ons → **Mosquitto broker** → install + start. Add a
   user (Settings → People/Users, or the add-on's `logins:`), e.g. `frigate` / a password. This is the
   broker itself; without it you get camera streams but no `binary_sensor.*_motion/_person`.
2. **MQTT integration (HA subscribes to the broker)** — **this is a distinct step from installing the
   add-on, and skipping it is the #1 gotcha.** Settings → Devices & Services → look for a *Discovered:
   MQTT* card → **Configure**; if there's none, **Add Integration → MQTT** → broker `core-mosquitto`
   (or `localhost`), port `1883`, username/password the `frigate` user. Installing the broker add-on
   does NOT auto-subscribe HA — until this integration shows **Connected**, the Frigate integration
   creates only `update.frigate` / `update.frigate_server` (it can reach Frigate's HTTP API) but **ZERO
   camera entities** (no MQTT discovery). That exact symptom = this step was skipped.
   *Verify the path:* MQTT integration → **Configure → Listen to a topic** → `frigate/#` → Start — you
   should see `frigate/available` → `online` and stats. Messages flowing = broker + integration + Frigate
   all aligned on the same broker.
3. **Frigate MQTT creds** — the `mqtt:` block in `config.yaml` is **disabled by default** (so the
   cameras load even before Mosquitto exists). Once the broker + MQTT user are up: **tell Claude to
   flip `mqtt.enabled: true` in the repo and push** (boxes pull only — a box can't push that edit),
   then run `./configs/frigate/enable-mqtt.sh` on NUC-2 to store the MQTT user/password in the
   gitignored `.env`, `git pull`, and redeploy with `frigate.sh`.
   (Order: Mosquitto first, then the flag. `MQTT Not authorized` in Frigate's logs = the user/pass in
   `.env` doesn't match the broker user — re-run `enable-mqtt.sh` and force-recreate.)
4. **Frigate integration** — HACS → install **Frigate** (`blakeblackshear/frigate-hass-integration`)
   → restart HA → Settings → Devices & Services → Add Integration → **Frigate** → URL
   `http://frigate-lxc.home.alexjenkinson.com:8971` (or `:5000`). With the MQTT integration (step 2)
   connected, it auto-discovers the cameras via MQTT and creates `camera.<room>`,
   `binary_sensor.<room>_motion`, `binary_sensor.<room>_person` (occupancy), fps sensors, and clips in
   Media. If it was added *before* step 2 was connected, reload it (⋮ → Reload) or restart HA so the
   cameras populate.

**Live view:** the integration's `camera.*` entities work in any picture card. For a low-latency live
feed, install the **Frigate Lovelace card** (HACS) — it uses Frigate's own go2rtc/WebRTC. Optional.

Then re-run the `/api/states` dump → the dashboard's camera-ready Security tab gets the real cards
(live tiles + motion/person chips per room).

**Build order:** Stage 1 → re-dump entities → I wire the Security tab + assess which cams have RTSP →
Stage 3 Frigate config for those → Stage 2 RoboVac whenever. Each stage stands alone.
