# HA sensors to buy — rental-friendly shortlist

Everything here is **removable and non-invasive**: battery Zigbee sensors (stick-on or free-standing)
or plug-in devices. No rewiring, no plumbing, nothing that needs landlord sign-off. All in your
existing **Sonoff / Aqara Zigbee** ecosystem.

Prices are rough UK figures (Nov 2026) — check before buying. Each item lists the HA feature it unlocks.

## Prerequisite — Zigbee coordinator

If you don't already have one on the HA box, everything below needs it (one-time):

| Item | Example | ~£ | Notes |
|---|---|---|---|
| Zigbee coordinator | Sonoff ZBDongle-E (Zigbee 3.0 USB Dongle Plus) | ~£20 | USB stick into the HA host; pair with ZHA or Zigbee2MQTT. Skip if you have one already. |

## The sensors

| Item | Example model | ~£ ea | Qty idea | Unlocks |
|---|---|---|---|---|
| **Temp + humidity** | Aqara T&H Sensor T1 (`WSDCGQ11LM`) | ~£15 | 3–4 (per main room) | **Mould/dewpoint indicator** (damp-risk alerts), room climate, heating logic later |
| **Water leak** | Aqara Water Leak Sensor T1 | ~£15 | 2–3 | Leak **alerts** under sink / washing machine / boiler (alert only — see note) |
| **Door/window contact** | Aqara Door & Window Sensor (`MCCGQ11LM`) | ~£13 | 3–5 | "Window open while heating's on", "front door left open", feeds an alarm |
| **Motion** | Sonoff SNZB-03 (~£7) or Aqara P1 (`RTCGQ14LM`, ~£15) | £7–15 | 2–3 | **Night motion lights** (low-brightness hall/bathroom), alarm trigger |
| **Ambient light (lux)** | Aqara Light Sensor T1 (`GZCGQ11LM`) | ~£15 | 1–2 | **True light-level triggers** in OTHER rooms. The office is sorted — the Hue motion sensor was moved there and its illuminance now drives the weekend sunset-lights automation (peaks ~1000–1600 lux, fires when it drops below 20). Only worth buying for a room with no Hue/motion sensor already reporting lux. |
| **Power-monitoring smart plug** | Aqara Smart Plug EU (`SP-EUC01`) or Sonoff S60TPF | ~£18 | 2–3 | **Appliance-done pings** (washer/dryer/dishwasher) + populates the empty `device_consumption` in your Energy Dashboard |
| **Zigbee siren** *(optional)* | Sonoff/Heiman Zigbee siren | ~£20 | 1 | Audible alarm if you add Alarmo (arm-away using the contact/motion sensors) |

### Rough spend
- **Core set** (coordinator if needed + ~3 T&H + 2 leak + 3 contact + 2 motion + 2 plugs): **~£150–180**
- Add the siren + more plugs later as wanted.

## Deliberately left off (not rental-friendly)
- **Automatic water shut-off (motorised stopcock)** — needs plumbing. Leak sensors above still *alert* you; the shut-off is the part you skip.
- **Smart TRVs / thermostat** — reversible in theory (you keep the original valve head), but it's a per-radiator cost and your tenancy may not make it worth it. Parked unless you want it.

## What each sensor enables, as HA features
Once these are paired, these are build-ready (I can script them into the repo + go live, same as vitamins):
- **Mould/dewpoint** ← temp+humidity sensors
- **Night motion lights** ← motion sensors (+ your existing Hue)
- **True light-level lighting** (incl. the weekend office sunset automation) ← ambient light/lux sensor on the SE windowsill
- **Window-open-while-heating / door-left-open** ← contact sensors
- **Appliance-done + per-device energy** ← power plugs
- **Leak alerts** ← leak sensors
- **Alarmo (arm-away)** ← contact + motion (+ optional siren), reusing your Frigate cameras

Software-only extras that need **no** hardware (not on this list): battery-low watchdog, device-offline
watchdog, flea/worming + renewal reminders. (Octopus tariff load-shifting is out — you're on a flat
tariff, so there are no cheap half-hours to shift to.)
