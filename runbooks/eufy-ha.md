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

## This home's split (decided)

- **4 indoor cams — all wired, all native RTSP → Frigate.** The Frigate config is already written
  (`configs/frigate/config.yaml`, Stage 3). No eufy-security-ws needed for these — they stream RTSP
  directly, go2rtc just restreams.
- **Doorbell — battery → `eufy_security` integration** (Stage 1). Sleeps, so it can't go in Frigate;
  the integration gives the press event, on-demand view and motion.
- **RoboVac → `bmccluskey/robovac`** (Stage 2).

## Stage 1 — eufy-security-ws + the eufy_security integration (for the battery doorbell)

Needed for the battery doorbell (press events, motion, on-demand view) and any other Eufy device the
Frigate path doesn't cover.

**Prereq: make a SECONDARY Eufy account.** The integration holds a login session; if it uses your
main account you get logged out of the phone app constantly and hit 2FA churn. In the Eufy app
(main account) → add a guest/shared member, give it access to the HomeBase + devices, use THAT
account's email/password below.

1. **Add-on** — Settings → Add-ons → Store → ⋮ → Repositories → add
   `https://github.com/bropat/hassio-eufy-security-ws` → install **Eufy Security Add-on**. Configure:
   `username` (secondary account), `password`, `country: GB`, `trusted_device_name: homeassistant`.
   Start it. (It listens on `:3000`.)
2. **go2rtc / WebRTC** — already installed here (WebRTC Camera / `update.webrtc_camera`). Nothing to do.
3. **Integration** — HACS → search **Eufy Security** → install → restart HA. Settings → Devices &
   Services → Add Integration → **Eufy Security** → host `127.0.0.1`, port `3000`. Handle the captcha
   + 2FA prompts via **Reconfigure** if they appear.
4. In the Eufy app set **Streaming Quality + Codec to LOW** on each cam (P2P is bandwidth-heavy).
5. Entities appear as `camera.*`, plus `binary_sensor.*` (motion/person), `sensor.*` (battery), and
   doorbell events. **Re-run the `/api/states` dump and send it** — the dashboard Security tab is
   camera-ready and I'll drop the real cards in.

## Stage 2 — Eufy RoboVac into HA

RoboVacs are **not** part of eufy_security — they're local Tuya devices.

1. HACS → ⋮ → Custom repositories → add `https://github.com/bmccluskey/robovac` (category Integration)
   → install → restart HA.
2. Settings → Devices & Services → Add Integration → **RoboVac**. Newer versions pull the device id +
   local key from your Eufy account login; older ones need the **device ID + local key** (get them
   with the Tuya/eufy key extractor the repo README links). Model matters — the repo lists supported
   RoboVacs; if yours is newer (L60/X-series/Omni) check the open issues for the right fork.
3. You get a `vacuum.*` entity (start/stop/return/clean) + battery/status — it goes on a new
   **Cleaning** dashboard card.

## Stage 3 — Frigate (LXC 111, nuc2) — the 4 indoor cams

`configs/frigate/config.yaml` is **already written** for the 4 wired indoor cams: each is a go2rtc
stream `rtsp://{FRIGATE_RTSP_USER}:{FRIGATE_RTSP_PASSWORD}@cam-<room>.home.alexjenkinson.com:554/live0`,
and Frigate detects+records off go2rtc on localhost. What's left is turning RTSP on and pointing DNS:

1. **Enable RTSP on each indoor cam** — Eufy app → the camera → Settings → **RTSP** → enable. Eufy
   lets you set a username + password; use the **same pair on all 4** (the config uses one credential
   set). Confirm the stream path is `/live0` (most Eufy cams); if a cam differs, change only that
   camera's go2rtc URL.
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
needs. Two pieces:

1. **MQTT broker** — HA → Settings → Add-ons → **Mosquitto broker** → install + start. In HA add a
   user (Settings → People/Users, or the add-on's `logins:`), e.g. `frigate` / a password. This is
   what carries Frigate's detection events to HA; without it you get the camera streams but no
   `binary_sensor.*_motion/_person`.
2. **Enable MQTT in Frigate** — put `FRIGATE_MQTT_USER` / `FRIGATE_MQTT_PASSWORD` in
   `configs/frigate/.env`, flip the `mqtt:` block in `config.yaml` to the enabled form (commented
   there), redeploy with `frigate.sh`.
3. **Frigate integration** — HACS → install **Frigate** (`blakeblackshear/frigate-hass-integration`)
   → restart HA → Settings → Devices & Services → Add Integration → **Frigate** → URL
   `http://frigate-lxc.home.alexjenkinson.com:8971` (or `:5000`). It auto-discovers the cameras via
   MQTT and creates `camera.<room>`, `binary_sensor.<room>_motion`, `binary_sensor.<room>_person`
   (occupancy), fps sensors, and the clips in Media.

**Live view:** the integration's `camera.*` entities work in any picture card. For a low-latency live
feed, install the **Frigate Lovelace card** (HACS) — it uses Frigate's own go2rtc/WebRTC. Optional.

Then re-run the `/api/states` dump → the dashboard's camera-ready Security tab gets the real cards
(live tiles + motion/person chips per room).

**Build order:** Stage 1 → re-dump entities → I wire the Security tab + assess which cams have RTSP →
Stage 3 Frigate config for those → Stage 2 RoboVac whenever. Each stage stands alone.
