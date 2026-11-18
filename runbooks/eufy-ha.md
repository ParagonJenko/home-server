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

## This home's split (rebuilt on the eufy-sdk stack — 2026-11-18)

**The old bropat stack is dead for this account.** `bropat/hassio-eufy-security-ws` +
`fuatakgun/eufy_security` authenticate fine but return **"No devices found / No stations found / No
houses found"** on Eufy **Mega** accounts — Eufy's new cloud returns success code `200` where the old
client only accepts `0` ([eufy-security-client #956](https://github.com/bropat/eufy-security-client/issues/956)).
This account is a Mega account, so that stack can never see the devices. **Removed and replaced** with
the maintained **eufy-sdk** stack (Stage 1). Symptoms that confirm you're hitting this: add-on log shows
`getPassportProfile` errors + repeated `No devices found` despite a successful login.

- **Doorbell (battery, E340 / T8214) → eufy-sdk.** It sleeps, so it stays out of Frigate. eufy-sdk gives
  `camera.doorbell` (on-demand), `event.doorbell_doorbell` (ring) + `binary_sensor.doorbell_ringing`,
  `binary_sensor.doorbell_motion` / `_person`, `image.doorbell_last_event`, battery, package detection —
  wired into the dashboard Security tab.
- **4 indoor cams (Living Room/Kitchen/Bedroom/Basement) → two ways:**
  1. **Frigate** pulls each over RTSP for 24/7 recording + OpenVINO detection (the primary path; see
     `configs/frigate/config.yaml`). NOTE: the cams were physically wired to the wrong `cam-<room>.home`
     DNS names, so the go2rtc URLs are **swap-corrected** there (living-room↔bedroom, kitchen↔basement).
  2. **eufy-sdk** also exposes them directly as `camera.<room>` with correct Eufy device names and a
     per-camera `sensor.<room>_rtsp_url` + `switch.<room>_rtsp_stream`. This is the clean source of truth
     for the real room↔camera mapping; a future tidy-up is to point Frigate at these RTSP URLs instead of
     the DNS-name hack.
- **RoboVac (T2118) → eufy-sdk** surfaces telemetry sensors; control (`vacuum.robovac`) comes from
  `damacus/robovac` (Stage 2).

## Stage 1 — the eufy-sdk stack (bridge add-on + integration) — REQUIRED for the doorbell + Eufy devices

Built for Eufy **Mega** accounts (which the old bropat stack can't handle). Two parts: a **bridge
add-on** (WS control + HTTP video + go2rtc) and the **eufy-sdk HACS/Marketplace integration** that talks
to it. Most of this is drivable from the HA-MCP connector (`ha_manage_app` / `ha_manage_hacs`); the Eufy
login + 2FA are yours. Docs: <https://mega-yfue.github.io/>.

1. **Bridge add-on** — Settings → Add-ons → Store → ⋮ → Repositories → add
   `https://github.com/mega-yfue/ha-eufy-sdk-addon` → install **eufy-sdk bridge**. Configuration tab:
   your **OWNER** Eufy account email + password (NOT a shared/secondary account — Mega accounts don't
   expose shared devices to the API, only owned ones), `country: GB`. Enable Watchdog + Start on boot,
   **Start**. It listens on `:3000` (WS/HTTP) + `:8554` (RTSP); if it collides on `:1984`, the WebRTC
   Camera integration owns that port — remove WebRTC Camera (Frigate has its own go2rtc) or remap it.
2. **Integration** — **Settings → Marketplace** → ⋮ → Add custom repository `mega-yfue/ha-eufy-sdk`
   (category Integration) → install → **restart HA**.
3. **Add it** — Settings → Devices & Services → Add Integration → **eufy-sdk** → it auto-discovers the
   bridge → enter the **2FA code Eufy emails** (fast — it expires; request a fresh one if it rejects).
   The 2FA is entered HERE in the integration, not in the add-on (the bridge logs `auth required:
   require_2fa` and waits for the integration to submit it).
4. Devices enumerate immediately: doorbell, the 4 cams, the RoboVac. Entity IDs are `camera.<name>`,
   `binary_sensor.<name>_motion/_person/_ringing`, `event.<name>_doorbell`, `image.<name>_last_event`,
   `sensor.<name>_battery`/`_rtsp_url`, plus a deep set of switches/selects/numbers per device.

**Gotcha:** only one client holds a Eufy station's P2P at a time — running the bridge can knock the
phone app's live view, and vice versa. Expected, not a fault.

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
