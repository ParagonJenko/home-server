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

| Camera | Continuous stream? | Path |
|---|---|---|
| Non-Eufy cam (living-room `10:2C:B1…`) with native RTSP | yes | straight into Frigate — ideal |
| Wired Eufy cam / wired doorbell | yes (go2rtc holds the eufy-security-ws stream open) | camera → go2rtc → Frigate → HA |
| **Battery** Eufy cam | **no — it sleeps to save battery** | fall back to `eufy_security` integration (on-demand view + Eufy's own motion events), NOT Frigate |
| Eufy RoboVac | n/a | `bmccluskey/robovac` HACS integration → `vacuum.*` |

So: Frigate is the hub for anything that streams continuously (RTSP cams + wired Eufy). Battery Eufy
cams physically can't do 24/7 detection — for those the `eufy_security` integration gives on-demand
view + Eufy-side motion, which is the best achievable. Know which of your Eufy cams are wired vs
battery — that decides which go through Frigate.

## Stage 1 — eufy-security-ws + the eufy_security integration

This stage is needed either way: it's the **stream source** Frigate/go2rtc pulls wired Eufy cams
from, *and* the on-demand fallback for battery cams that can't go through Frigate.

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

## Stage 3 — Frigate as the hub (LXC 111, nuc2)

Each continuous-stream camera goes into Frigate's `config.yml` via its built-in **go2rtc**:
- **Non-Eufy RTSP cams** (living-room `10:2C:B1:…`) — enable RTSP in their own app, get
  `rtsp://user:pass@<ip>:554/<path>`, add it as a go2rtc stream, point a Frigate camera at it.
- **Wired Eufy cams** — go2rtc pulls the stream from **eufy-security-ws** (Stage 1). The
  eufy_security integration registers the cam with go2rtc when the livestream starts; Frigate's
  go2rtc references that so the stream stays up for detection. Wired only — a battery cam sleeps and
  the stream drops.
- **Battery Eufy cams** — not in Frigate; the eufy_security integration handles them on-demand.

Pattern per camera: **detect on a low-res substream, record on the main stream** (keeps CPU/RAM sane
on the Frigate LXC). The HA **Frigate integration** then surfaces `camera.<name>`,
`binary_sensor.<name>_motion` / `_person`, snapshots and clips — which slot straight into the
dashboard's Security tab. RTSP-discovery + substream mechanics are in `cameras.md`; this file is the
Eufy/HA-specific layer. I'll write the actual `config.yml` camera blocks once we know each camera's
real stream URL (wired vs battery, RTSP available or not).

**Build order:** Stage 1 → re-dump entities → I wire the Security tab + assess which cams have RTSP →
Stage 3 Frigate config for those → Stage 2 RoboVac whenever. Each stage stands alone.
