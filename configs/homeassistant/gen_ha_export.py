#!/usr/bin/env python3
"""Generate repo-tracked YAML for the HA automations + helpers created via HA-MCP.
Faithful copies of what was deployed live, so HA's own config is reproducible like the LXCs."""
import yaml, pathlib

OUT = pathlib.Path("/home/claude/home-server/configs/homeassistant")
(OUT / "").mkdir(parents=True, exist_ok=True)

automations = [
    {
        "id": "1795039639885",
        "alias": "Doorbell → phone (snapshot)",
        "description": "Doorbell pressed: push a live doorbell snapshot to Alex's phone.",
        "mode": "single",
        "triggers": [{"trigger": "state", "entity_id": "binary_sensor.doorbell_ringing", "to": "on"}],
        "actions": [{
            "action": "notify.mobile_app_alexs_iphone",
            "data": {"title": "\U0001f514 Doorbell", "message": "Someone's at the front door",
                     "data": {"image": "/api/camera_proxy/camera.doorbell", "tag": "doorbell", "group": "security"}},
        }],
    },
    {
        "id": "1795039640817",
        "alias": "Person detected while away",
        "description": "Frigate sees a person in a room while Alex is away: push an alert with that room's camera snapshot.",
        "mode": "parallel",
        "max": 10,
        "triggers": [{"trigger": "state",
                      "entity_id": ["binary_sensor.living_room_person", "binary_sensor.kitchen_person",
                                    "binary_sensor.bedroom_person", "binary_sensor.basement_person"],
                      "to": "on"}],
        "conditions": [{"condition": "state", "entity_id": "person.alex_jenkinson", "state": "not_home"}],
        "variables": {
            "cam": ("{{ {'binary_sensor.living_room_person':'camera.living_room_cam_living_room',"
                    "'binary_sensor.kitchen_person':'camera.living_room_cam_kitchen',"
                    "'binary_sensor.bedroom_person':'camera.bedroom_cam_bedroom',"
                    "'binary_sensor.basement_person':'camera.utility_cam_basement'}"
                    ".get(trigger.entity_id,'camera.doorbell') }}"),
            "room": "{{ trigger.to_state.attributes.friendly_name | replace(' Person','') }}",
        },
        "actions": [{
            "action": "notify.mobile_app_alexs_iphone",
            "data": {"title": "\U0001f441️ Person detected — you're away",
                     "message": "Someone is in the {{ room }}",
                     "data": {"image": "/api/camera_proxy/{{ cam }}", "tag": "person_away_{{ room }}", "group": "security"}},
        }],
    },
    {
        "id": "1795039641592",
        "alias": "Arrive home (dark) → living room lights",
        "description": "When Alex gets home while the sun is below the horizon, turn on the living room lights.",
        "mode": "single",
        "triggers": [{"trigger": "state", "entity_id": "person.alex_jenkinson", "to": "home"}],
        "conditions": [{"condition": "state", "entity_id": "sun.sun", "state": "below_horizon"}],
        "actions": [{"action": "light.turn_on", "target": {"entity_id": "light.living_room_living_room"}}],
    },
    {
        "id": "1795039642577",
        "alias": "Leave home → all lights off",
        "description": "When Alex leaves (debounced 2 min), turn off all lights. Single occupant, so not_home = empty house.",
        "mode": "single",
        "triggers": [{"trigger": "state", "entity_id": "person.alex_jenkinson", "to": "not_home", "for": {"minutes": 2}}],
        "actions": [{"action": "light.turn_off", "target": {"entity_id": "all"}}],
    },
    {
        "id": "1795039995065",
        "alias": "Litter tray full → hourly phone alert",
        "description": "PetKit Pura Max (RobertD502 integration): binary_sensor.litter_tray_wastebin correctly reports a full waste bin. Fires when it goes on, re-nags hourly, self-clears when emptied.",
        "mode": "single",
        "triggers": [
            {"trigger": "state", "entity_id": "binary_sensor.litter_tray_wastebin", "to": "on"},
            {"trigger": "time_pattern", "hours": "/1"},
        ],
        "conditions": [{"condition": "state", "entity_id": "binary_sensor.litter_tray_wastebin", "state": "on"}],
        "actions": [{"action": "notify.mobile_app_alexs_iphone",
                     "data": {"title": "\U0001f6bd Litter tray full",
                              "message": "The PetKit waste bin is full — empty it.",
                              "data": {"tag": "litter_full", "group": "home"}}}],
    },
    {
        "id": "1795040260037",
        "alias": "Bin day: Monday heads-up",
        "description": "Every Monday at 12:00, tell Alex which bin is out this week (next collection within 5 days).",
        "mode": "single",
        "triggers": [{"trigger": "time", "at": "12:00:00"}],
        "conditions": [{"condition": "time", "weekday": ["mon"]}],
        "actions": [
            {"action": "calendar.get_events",
             "target": {"entity_id": "calendar.waste_collection_schedule_cheshire_east_council"},
             "data": {"start_date_time": "{{ now() }}", "end_date_time": "{{ now() + timedelta(days=5) }}"},
             "response_variable": "ev"},
            {"variables": {"items": "{{ ev['calendar.waste_collection_schedule_cheshire_east_council'].events }}"}},
            {"condition": "template", "value_template": "{{ items | count > 0 }}"},
            {"action": "notify.mobile_app_alexs_iphone",
             "data": {"title": "\U0001f5d1️ Bin this week",
                      "message": "This week's bin is {{ items[0].summary }} — out Wednesday.",
                      "data": {"tag": "bin_week", "group": "home"}}},
        ],
    },
    {
        "id": "1795040260770",
        "alias": "Bin day: night-before reminder",
        "description": "At 20:00 the evening before a collection, remind Alex to put the right bin out.",
        "mode": "single",
        "triggers": [{"trigger": "time", "at": "20:00:00"}],
        "actions": [
            {"action": "calendar.get_events",
             "target": {"entity_id": "calendar.waste_collection_schedule_cheshire_east_council"},
             "data": {"start_date_time": "{{ today_at('23:00') }}", "end_date_time": "{{ today_at('23:00') + timedelta(days=1) }}"},
             "response_variable": "ev"},
            {"variables": {"items": "{{ ev['calendar.waste_collection_schedule_cheshire_east_council'].events }}"}},
            {"condition": "template", "value_template": "{{ items | count > 0 }}"},
            {"action": "notify.mobile_app_alexs_iphone",
             "data": {"title": "\U0001f319 Bin night",
                      "message": "Put the {{ items[0].summary }} out tonight — collection tomorrow morning.",
                      "data": {"tag": "bin_night", "group": "home"}}},
        ],
    },
    {
        "id": "1795111688049",
        "alias": "Infra: host unreachable → phone",
        "description": "A homelab host (Prometheus ICMP bridge) unreachable for 10 min: push an alert naming it.",
        "mode": "parallel",
        "max": 6,
        "triggers": [{"trigger": "state",
                      "entity_id": ["binary_sensor.infra_nuc1", "binary_sensor.infra_nuc2",
                                    "binary_sensor.infra_pbs", "binary_sensor.infra_pi"],
                      "to": "off", "for": {"minutes": 10}}],
        "actions": [{"action": "notify.mobile_app_alexs_iphone",
                     "data": {"title": "\U0001f50c Host unreachable",
                              "message": "{{ trigger.to_state.attributes.friendly_name | replace('Infra ','') }} has been unreachable for 10 min.",
                              "data": {"tag": "infra_down_{{ trigger.entity_id }}", "group": "infra"}}}],
    },
    {
        "id": "1795111688783",
        "alias": "Infra: service(s) down → phone",
        "description": "One or more blackbox-http probes failing for 5 min (sensor.infra_services_down > 0): push an alert.",
        "mode": "single",
        "triggers": [{"trigger": "numeric_state", "entity_id": "sensor.infra_services_down",
                      "above": 0, "for": {"minutes": 15}}],
        "actions": [{"action": "notify.mobile_app_alexs_iphone",
                     "data": {"title": "⚠️ Service down",
                              "message": "{{ states('sensor.infra_services_down') }} service(s) are down — check Grafana.",
                              "data": {"tag": "infra_services_down", "group": "infra"}}}],
    },
    {
        "id": "1795123263298",
        "alias": "Vitamins: reset for the new day",
        "description": "Untick the daily vitamins toggle at 04:00 so it's fresh each morning.",
        "mode": "single",
        "triggers": [{"trigger": "time", "at": "04:00:00"}],
        "actions": [{"action": "input_boolean.turn_off", "target": {"entity_id": "input_boolean.vitamins_taken"}}],
    },
    {
        "id": "1795123264172",
        "alias": "Vitamins: reminder if not taken",
        "description": "Morning prompt (09:00) and an evening nag (19:30) to take vitamins, only if the toggle is still off. Push carries a 'Mark taken' button.",
        "mode": "single",
        "triggers": [{"trigger": "time", "at": "09:00:00"}, {"trigger": "time", "at": "19:30:00"}],
        "conditions": [{"condition": "state", "entity_id": "input_boolean.vitamins_taken", "state": "off"}],
        "actions": [{"action": "notify.mobile_app_alexs_iphone",
                     "data": {"title": "\U0001f48a Vitamins", "message": "You haven't ticked your vitamins today.",
                              "data": {"tag": "vitamins",
                                       "actions": [{"action": "VITAMINS_TAKEN", "title": "Mark taken"}]}}}],
    },
    {
        "id": "1795123264992",
        "alias": "Vitamins: mark taken from notification",
        "description": "Tapping 'Mark taken' on the reminder ticks the toggle and clears the notification.",
        "mode": "single",
        "triggers": [{"trigger": "event", "event_type": "mobile_app_notification_action",
                      "event_data": {"action": "VITAMINS_TAKEN"}}],
        "actions": [
            {"action": "input_boolean.turn_on", "target": {"entity_id": "input_boolean.vitamins_taken"}},
            {"action": "notify.mobile_app_alexs_iphone",
             "data": {"message": "clear_notification", "data": {"tag": "vitamins"}}},
        ],
    },
    # ---- WFH circadian lighting (08:00-17:00). Office is schedule-driven (decoupled from the sun so
    # it doesn't warm/dim through dark winter afternoons); the rest of the flat stays on Adaptive Lighting.
    {
        "id": "1795203406117",
        "alias": "Office: work-mode daylight",
        "description": "On weekdays during work hours, hold the office at bright cool-white for focus. Fires at work start and whenever the office light is switched on during work hours.",
        "mode": "restart",
        "triggers": [{"trigger": "time", "at": "input_datetime.work_start"},
                     {"trigger": "state", "entity_id": "light.office_office", "to": "on"}],
        "conditions": [
            {"condition": "time", "after": "input_datetime.work_start", "before": "input_datetime.work_end",
             "weekday": ["mon", "tue", "wed", "thu", "fri"]},
            {"condition": "state", "entity_id": "input_boolean.work_lighting", "state": "on"},
            {"condition": "state", "entity_id": "light.office_office", "state": "on"},
        ],
        "actions": [{"action": "light.turn_on", "target": {"entity_id": "light.office_office"},
                     "data": {"color_temp_kelvin": 5300, "brightness_pct": 100, "transition": 3}}],
    },
    {
        "id": "1795511411017",
        "alias": "Office: auto-bright on dark work days",
        "description": ("During weekday work hours, if the office is dim (below 100 lux) and I'm in there "
                        "with the lights off, bring them up to bright daylight — so I never work in the dark "
                        "on a gloomy winter morning/afternoon. Complements 'work-mode daylight' (which holds "
                        "daylight once the light is on); THIS one does the turning-on. Raise the lux number "
                        "to keep it bright more of the day; lower it to only kick in when quite dark."),
        "mode": "restart",
        # Fires when the room darkens, when I arrive (motion), or at work start if it's already dark.
        "triggers": [
            {"trigger": "numeric_state", "entity_id": "sensor.hue_motion_sensor_illuminance", "below": 100,
             "for": {"minutes": 2}},
            {"trigger": "state", "entity_id": "binary_sensor.hue_motion_sensor_motion", "to": "on"},
            {"trigger": "time", "at": "input_datetime.work_start"},
        ],
        # Weekday work hours (the time window also blocks the dawn re-arm of the numeric trigger); dim NOW;
        # lights currently off (so it only turns on — work-mode daylight keeps them bright after); and I'm
        # about (motion now or within 20 min). Occupancy + light-off keep it from lighting an empty office
        # or fighting a manual off in bright conditions.
        "conditions": [
            {"condition": "time", "after": "input_datetime.work_start", "before": "input_datetime.work_end",
             "weekday": ["mon", "tue", "wed", "thu", "fri"]},
            {"condition": "state", "entity_id": "input_boolean.work_lighting", "state": "on"},
            {"condition": "numeric_state", "entity_id": "sensor.hue_motion_sensor_illuminance", "below": 100},
            {"condition": "state", "entity_id": "light.office_office", "state": "off"},
            {"condition": "template",
             "value_template": ("{{ is_state('binary_sensor.hue_motion_sensor_motion','on') or "
                                "(states.binary_sensor.hue_motion_sensor_motion.last_changed is not none and "
                                "(now() - states.binary_sensor.hue_motion_sensor_motion.last_changed).total_seconds() < 1200) }}")},
        ],
        "actions": [{"action": "light.turn_on", "target": {"entity_id": "light.office_office"},
                     "data": {"color_temp_kelvin": 5300, "brightness_pct": 100, "transition": 3}}],
    },
    {
        "id": "1795203406832",
        "alias": "Office: clock-out warm cue",
        "description": "At work end on weekdays, shift the office to warm/dim as a visible 'stop working' boundary. Only if the office light is on.",
        "mode": "single",
        "triggers": [{"trigger": "time", "at": "input_datetime.work_end"}],
        "conditions": [
            {"condition": "time", "weekday": ["mon", "tue", "wed", "thu", "fri"]},
            {"condition": "state", "entity_id": "input_boolean.work_lighting", "state": "on"},
            {"condition": "state", "entity_id": "light.office_office", "state": "on"},
        ],
        "actions": [{"action": "light.turn_on", "target": {"entity_id": "light.office_office"},
                     "data": {"color_temp_kelvin": 2700, "brightness_pct": 60, "transition": 5}}],
    },
    {
        "id": "1795203407536",
        "alias": "Bedroom: sunrise wake",
        "description": "Gentle 20-minute ramp to soft daylight in the bedroom on weekday mornings.",
        "mode": "single",
        "triggers": [{"trigger": "time", "at": "input_datetime.bedroom_wake_time"}],
        "conditions": [{"condition": "time", "weekday": ["mon", "tue", "wed", "thu", "fri"]}],
        "actions": [{"action": "light.turn_on", "target": {"entity_id": "light.bedroom_bedroom"},
                     "data": {"color_temp_kelvin": 4000, "brightness_pct": 80, "transition": 1200}}],
    },
    {
        "id": "1795203408273",
        "alias": "Bedroom: evening wind-down",
        "description": "On weekday nights at the wind-down time, if the bedroom light is on, drop it to warm/dim to protect sleep.",
        "mode": "single",
        "triggers": [{"trigger": "time", "at": "input_datetime.bedroom_wind_down"}],
        "conditions": [{"condition": "time", "weekday": ["mon", "tue", "wed", "thu", "fri"]},
                       {"condition": "state", "entity_id": "light.bedroom_bedroom", "state": "on"}],
        "actions": [{"action": "light.turn_on", "target": {"entity_id": "light.bedroom_bedroom"},
                     "data": {"color_temp_kelvin": 2200, "brightness_pct": 30, "transition": 60}}],
    },
    {
        "id": "1795203408978",
        "alias": "Office: movement nudge",
        "description": "A gentle Play-bar flash through the workday to prompt standing up / looking away. Lunch at 12:00, so the midday gap is 12:00-13:00. Toggle with input_boolean.work_movement_nudge.",
        "mode": "single",
        "triggers": [{"trigger": "time", "at": "10:30:00"}, {"trigger": "time", "at": "14:00:00"},
                     {"trigger": "time", "at": "16:00:00"}],
        "conditions": [
            {"condition": "time", "weekday": ["mon", "tue", "wed", "thu", "fri"]},
            {"condition": "state", "entity_id": "input_boolean.work_lighting", "state": "on"},
            {"condition": "state", "entity_id": "input_boolean.work_movement_nudge", "state": "on"},
            {"condition": "state", "entity_id": "light.office_hue_play_1", "state": "on"},
        ],
        "actions": [{"action": "light.turn_on", "target": {"entity_id": "light.office_hue_play_1"},
                     "data": {"flash": "long"}}],
    },
    {
        "id": "1795203783988",
        "alias": "Work lighting: re-arm each morning",
        "description": "Turn the work-lighting master back on at 04:00 on weekdays, so tapping 'End work' early only ends today, not tomorrow.",
        "mode": "single",
        "triggers": [{"trigger": "time", "at": "04:00:00"}],
        "conditions": [{"condition": "time", "weekday": ["mon", "tue", "wed", "thu", "fri"]}],
        "actions": [{"action": "input_boolean.turn_on", "target": {"entity_id": "input_boolean.work_lighting"}}],
    },
    # ---- Litter waste-bin forecast: track last-emptied, self-calibrate the fill interval, warn a day early.
    {
        "id": "1795213977620",
        "alias": "Litter: record emptied",
        "description": "When the waste bin clears (full -> not full), stamp 'last emptied' = now, which resets the days-since counter and the predicted-full date.",
        "mode": "single",
        "triggers": [{"trigger": "state", "entity_id": "binary_sensor.litter_tray_wastebin", "from": "on", "to": "off"}],
        "actions": [{"action": "input_datetime.set_datetime", "target": {"entity_id": "input_datetime.litter_last_emptied"},
                     "data": {"timestamp": "{{ now().timestamp() }}"}}],
    },
    {
        "id": "1795213978391",
        "alias": "Litter: learn fill interval",
        "description": "When the bin reports full, fold the days-since-emptied (the just-completed cycle length) into the fill-days estimate with 2:1 smoothing, so the prediction self-calibrates. Skips spurious cycles under 1 day.",
        "mode": "single",
        "triggers": [{"trigger": "state", "entity_id": "binary_sensor.litter_tray_wastebin", "from": "off", "to": "on"}],
        "conditions": [{"condition": "numeric_state", "entity_id": "sensor.litter_days_since_emptied", "above": 1}],
        "actions": [{"action": "input_number.set_value", "target": {"entity_id": "input_number.litter_fill_days"},
                     "data": {"value": "{{ (((states('input_number.litter_fill_days') | float(5) * 2) + states('sensor.litter_days_since_emptied') | float(5)) / 3) | round(1) }}"}}],
    },
    {
        "id": "1795213979121",
        "alias": "Litter: heads-up before full",
        "description": "A day before the waste bin is predicted to fill (and it isn't already full), push a heads-up with the predicted date.",
        "mode": "single",
        "triggers": [{"trigger": "state", "entity_id": "binary_sensor.litter_fill_due_soon", "from": "off", "to": "on"}],
        "actions": [{"action": "notify.mobile_app_alexs_iphone",
                     "data": {"title": "\U0001f43e Litter bin filling up",
                              "message": "The waste bin is likely full within a day (≈{{ as_timestamp(states('sensor.litter_predicted_full')) | timestamp_custom('%a %-d %b') }}). Empty it soon.",
                              "data": {"tag": "litter_due_soon", "group": "home"}}}],
    },
    # ---- Projected energy bill: accrue yesterday's cost nightly, reset monthly, warn over budget.
    {
        "id": "1795214839126",
        "alias": "Energy: accrue daily cost",
        "description": "Just after midnight, add yesterday's total electricity + gas cost (both include standing charge) to the month-to-date and tick the days-accrued counter. Feeds the projected-bill run-rate.",
        "mode": "single",
        "triggers": [{"trigger": "time", "at": "00:10:00"}],
        "actions": [
            {"action": "input_number.set_value", "target": {"entity_id": "input_number.energy_month_to_date"},
             "data": {"value": "{{ (states('input_number.energy_month_to_date')|float(0) + states('sensor.octopus_energy_electricity_19m0059512_1610012030180_previous_accumulative_cost')|float(0) + states('sensor.octopus_energy_gas_e6s17297892061_9384989210_previous_accumulative_cost')|float(0)) | round(2) }}"}},
            {"action": "counter.increment", "target": {"entity_id": "counter.energy_days_accrued"}},
        ],
    },
    {
        "id": "1795214840551",
        "alias": "Energy: reset monthly totals",
        "description": "On the 1st, zero the month-to-date and days-accrued so the projection restarts for the new month. Runs just before the daily accrual.",
        "mode": "single",
        "triggers": [{"trigger": "time", "at": "00:05:00"}],
        "conditions": [{"condition": "template", "value_template": "{{ now().day == 1 }}"}],
        "actions": [
            {"action": "input_number.set_value", "target": {"entity_id": "input_number.energy_month_to_date"}, "data": {"value": 0}},
            {"action": "counter.reset", "target": {"entity_id": "counter.energy_days_accrued"}},
        ],
    },
    {
        "id": "1795214841217",
        "alias": "Energy: projected over budget",
        "description": "When the projected monthly bill crosses the budget, push an alert once.",
        "mode": "single",
        "triggers": [{"trigger": "state", "entity_id": "binary_sensor.energy_over_budget", "from": "off", "to": "on"}],
        "actions": [{"action": "notify.mobile_app_alexs_iphone",
                     "data": {"title": "\U0001f4b7 Energy over budget",
                              "message": "Projected this month ≈ £{{ states('sensor.energy_projected_bill') }} — over your £{{ states('input_number.energy_monthly_budget')|int }} budget.",
                              "data": {"tag": "energy_budget", "group": "home"}}}],
    },
    # ---- Move goal: celebrate hitting the daily step goal, one gentle after-work nudge if behind.
    {
        "id": "1795215269320",
        "alias": "Steps: goal reached",
        "description": "Celebrate once when today's steps cross the goal. Positive reinforcement, fires once per day.",
        "mode": "single",
        "triggers": [{"trigger": "state", "entity_id": "binary_sensor.step_goal_met", "from": "off", "to": "on"}],
        "actions": [{"action": "notify.mobile_app_alexs_iphone",
                     "data": {"title": "\U0001f389 Step goal hit",
                              "message": "Nice one — {{ states('sensor.alexs_iphone_steps') }} steps today, goal smashed.",
                              "data": {"tag": "step_goal", "group": "home"}}}],
    },
    {
        "id": "1795215270081",
        "alias": "Steps: evening nudge",
        "description": ("One gentle after-work nudge at 17:30 if the step goal isn't met. Scales the "
                        "suggestion to how far off you are (no 'quick loop' when you're miles off). Looks "
                        "at the next 4h of the hourly forecast: if rain is due (precip > 0 or a wet "
                        "condition) it points at the walking pad / weights instead of a walk."),
        "mode": "single",
        "triggers": [{"trigger": "time", "at": "17:30:00"}],
        "conditions": [{"condition": "state", "entity_id": "binary_sensor.step_goal_met", "state": "off"}],
        # Step 1 pulls the hourly forecast into `fc`; the notify templates read the next 4h from it.
        # "wet" = any precip > 0 or a wet condition in that window (this weather integration gives mm,
        # not a % chance). Message also picks a tier (quick / decent / far-off) from steps remaining.
        # Walking pad is the indoor step substitute; weights get a mention for a change of pace.
        "actions": [
            {"action": "weather.get_forecasts", "data": {"type": "hourly"},
             "target": {"entity_id": "weather.home"}, "response_variable": "fc"},
            {"action": "notify.mobile_app_alexs_iphone",
             "data": {"title": (
                          "{%- set fcl = (fc.get('weather.home', {}).get('forecast', []))[:4] -%}\n"
                          "{%- set rainmm = [0] + (fcl | map(attribute='precipitation') | reject('none') | map('float', 0) | list) -%}\n"
                          "{%- set wet = (rainmm | max) > 0 or (fcl | selectattr('condition','in',"
                          "['rainy','pouring','snowy','snowy-rainy','hail','lightning-rainy']) | list | count > 0) -%}\n"
                          "{{ '\U0001f327 Rain due — pad instead?' if wet else '\U0001f45f Fancy a walk?' }}"),
                      "message": (
                          "{%- set fcl = (fc.get('weather.home', {}).get('forecast', []))[:4] -%}\n"
                          "{%- set rainmm = [0] + (fcl | map(attribute='precipitation') | reject('none') | map('float', 0) | list) -%}\n"
                          "{%- set wet = (rainmm | max) > 0 or (fcl | selectattr('condition','in',"
                          "['rainy','pouring','snowy','snowy-rainy','hail','lightning-rainy']) | list | count > 0) -%}\n"
                          "{%- set rem = states('sensor.steps_to_goal')|int(0) -%}\n"
                          "{%- set cur = states('sensor.alexs_iphone_steps')|int(0) -%}\n"
                          "{%- set goal = states('input_number.step_goal')|int(6000) -%}\n"
                          "{%- if rem <= 1500 -%}{%- set tier = 0 -%}"
                          "{%- elif rem <= 3500 -%}{%- set tier = 1 -%}"
                          "{%- else -%}{%- set tier = 2 -%}{%- endif -%}\n"
                          "{%- set dry = ['A quick loop would do it, no pressure.', "
                          "'A decent walk would get you there.', "
                          "'A fair way off — even a short walk or a stint on the walking pad chips at it.'] -%}\n"
                          "{%- set indoor = ['Rain due — 15 min on the walking pad would finish it.', "
                          "'Rain due — a walking-pad session would get you there.', "
                          "'Rain due — hop on the walking pad; even part counts, or grab the weights for a change.'] -%}\n"
                          "You're at {{ cur }} steps, {{ rem }} off your {{ goal }}. "
                          "{{ (indoor if wet else dry)[tier] }}"),
                      "data": {"tag": "step_nudge", "group": "home"}}},
        ],
    },
    {
        "id": "1795215539343",
        "alias": "Weight: Sunday weigh-in reminder",
        "description": "Every Sunday morning, a gentle reminder to do the weekly weigh-in. Weekly cadence tracks the trend without fixating on daily noise.",
        "mode": "single",
        "triggers": [{"trigger": "time", "at": "09:00:00"}],
        "conditions": [{"condition": "time", "weekday": ["sun"]}],
        "actions": [{"action": "notify.mobile_app_alexs_iphone",
                     "data": {"title": "⚖️ Weekly weigh-in",
                              "message": "Hop on the scales when you're up — same time each week keeps the trend honest. Currently {{ states('sensor.alexs_iphone_weight') }} kg, {{ states('sensor.weight_to_target') }} kg from your {{ states('input_number.weight_target')|int }}kg target.",
                              "data": {"tag": "weigh_in", "group": "home"}}}],
    },
    {
        "id": "1795216112338",
        "alias": "Doorbell: low battery reminder",
        "description": "Warn at 20% and again at 10% on the doorbell battery so it gets charged before it dies. The template condition is the recommended guard against re-firing when the sensor blips to unavailable (trigger.from_state has no native condition).",
        "mode": "single",
        "triggers": [{"trigger": "numeric_state", "entity_id": "sensor.doorbell_battery", "below": 20, "id": "low"},
                     {"trigger": "numeric_state", "entity_id": "sensor.doorbell_battery", "below": 10, "id": "critical"}],
        "conditions": [{"condition": "template", "value_template": "{{ trigger.from_state.state not in ['unknown','unavailable'] }}"}],
        "actions": [{"action": "notify.mobile_app_alexs_iphone",
                     "data": {"title": "{{ '🪫 Doorbell battery critical' if trigger.id == 'critical' else '🔋 Doorbell battery low' }}",
                              "message": "Doorbell is at {{ states('sensor.doorbell_battery') }}% — {{ 'charge it now.' if trigger.id == 'critical' else 'charge it soon.' }}",
                              "data": {"tag": "doorbell_battery", "group": "home"}}}],
    },
    {
        "id": "1795281091250",
        "alias": "Office weekend sunset lights",
        "description": ("On weekend afternoons, when the office actually gets dim (SE-window light level "
                        "below 20 lux, sustained 3 min), turn the office lights on warm IF I'm in there and "
                        "they're off. Now driven by the REAL light level: the Hue motion sensor was moved "
                        "into the office, so its illuminance tracks the SE window (observed ~1000-1600 lux "
                        "late-morning peak, falling below 20 around 14:45-15:40, just before sunset). Gated "
                        "to after 12:00 so the morning brightening can't trip the 'below' trigger. Raise the "
                        "lux number to fire earlier (more daylight left), lower it to fire closer to dark."),
        "mode": "single",
        # Real light-level trigger: fires on the afternoon decline through 20 lux, held 3 min to debounce.
        "triggers": [{"trigger": "numeric_state", "entity_id": "sensor.hue_motion_sensor_illuminance",
                      "below": 20, "for": {"minutes": 3}}],
        # Weekend AFTERNOON only (after 12:00 blocks the dawn rise re-arming the trigger); office occupied
        # (motion now, or cleared within 20 min — I sit still at the desk); and only if the office lights
        # are off, so it won't stomp a scene/relax mode I've set. The recency template has no native
        # equivalent (native `for:` measures continuous time, the opposite).
        "conditions": [
            {"condition": "time", "after": "12:00:00", "weekday": ["sat", "sun"]},
            {"condition": "template",
             "value_template": ("{{ is_state('binary_sensor.hue_motion_sensor_motion','on') or "
                                "(states.binary_sensor.hue_motion_sensor_motion.last_changed is not none and "
                                "(now() - states.binary_sensor.hue_motion_sensor_motion.last_changed).total_seconds() < 1200) }}")},
            {"condition": "state", "entity_id": "light.office_office", "state": "off"},
        ],
        "actions": [{"action": "light.turn_on", "target": {"entity_id": "light.office_office"},
                     "data": {"color_temp_kelvin": 2500, "brightness_pct": 60}}],
    },
    {
        "id": "1795366119564",
        "alias": "RoboVac: scheduled runs",
        "description": ("Starts the vacuum at 12:00 daily. Also at 19:00, but only if the battery is "
                        "at/above 95% (fully charged after the midday run). Offline/unavailable or not "
                        "charged → evening run skipped. The Eufy 30C exposes battery + error only, no "
                        "bin-full sensor, so emptying the bin stays manual."),
        "mode": "single",
        "triggers": [{"trigger": "time", "at": "12:00:00", "id": "midday"},
                     {"trigger": "time", "at": "19:00:00", "id": "evening"}],
        # Midday always; evening only when fully charged. `above: 94` = >=95% (unavailable fails it,
        # so an offline vac is skipped). sensor.robovac_battery is the real charge level the 30C reports.
        "conditions": [{"condition": "or", "conditions": [
            {"condition": "trigger", "id": "midday"},
            {"condition": "and", "conditions": [
                {"condition": "trigger", "id": "evening"},
                {"condition": "numeric_state", "entity_id": "sensor.robovac_battery", "above": 94}]}]}],
        "actions": [{"action": "vacuum.start", "target": {"entity_id": "vacuum.robovac"}}],
    },
    {
        "id": "1795368136888",
        "alias": "RoboVac: error alert",
        "description": ("Push when the RoboVac reports a real device error (stuck, brush/wheel jam, bin, "
                        "etc.) so it surfaces in HA, not just the Eufy app. Fires when sensor.robovac_error "
                        "is anything but 'No error'/unavailable/unknown. Connection drops are deliberately "
                        "ignored (too frequent — they show on the vacuum entity, not this sensor)."),
        "mode": "single",
        "triggers": [{"trigger": "state", "entity_id": "sensor.robovac_error"}],
        # `not (state in [the non-error values])` — native, no template. A real error string passes.
        "conditions": [{"condition": "not", "conditions": [
            {"condition": "state", "entity_id": "sensor.robovac_error",
             "state": ["No error", "unavailable", "unknown", "none", ""]}]}],
        "actions": [{"action": "notify.mobile_app_alexs_iphone",
                     "data": {"title": "\U0001f916 RoboVac error",
                              "message": "{{ states('sensor.robovac_error') }} — needs a hand.",
                              "data": {"tag": "robovac_error", "group": "home"}}}],
    },
]

# Scripts created via HA-MCP (tappable from the Home dashboard's "Work lighting" section).
scripts = {
    "office_focus": {
        "alias": "Office: focus", "icon": "mdi:brightness-7",
        "sequence": [{"action": "light.turn_on", "target": {"entity_id": "light.office_office"},
                      "data": {"color_temp_kelvin": 5300, "brightness_pct": 100, "transition": 2}}],
    },
    "office_break": {
        "alias": "Office: break", "icon": "mdi:coffee",
        "sequence": [{"action": "light.turn_on", "target": {"entity_id": "light.office_office"},
                      "data": {"color_temp_kelvin": 3000, "brightness_pct": 70, "transition": 2}}],
    },
    # One-tap end of day: set the office to the evening warm colour and flip the work-lighting
    # master off so work-mode won't snap it back to daylight. Re-armed at 04:00 next weekday.
    "end_work": {
        "alias": "End work", "icon": "mdi:briefcase-off",
        "sequence": [{"action": "input_boolean.turn_off", "target": {"entity_id": "input_boolean.work_lighting"}},
                     {"action": "light.turn_on", "target": {"entity_id": "light.office_office"},
                      "data": {"color_temp_kelvin": 2700, "brightness_pct": 60, "transition": 5}}],
    },
    # Cosy evening office: warm and low. Also disables work-lighting so work-mode can't fight it
    # (re-armed 04:00 next weekday).
    "relax_mode": {
        "alias": "Relax mode", "icon": "mdi:sofa",
        "sequence": [{"action": "input_boolean.turn_off", "target": {"entity_id": "input_boolean.work_lighting"}},
                     {"action": "light.turn_on", "target": {"entity_id": "light.office_office"},
                      "data": {"color_temp_kelvin": 2000, "brightness_pct": 25, "transition": 4}}],
    },
    # Separate cosy scene for the living room only.
    "living_room_relax": {
        "alias": "Living room relax", "icon": "mdi:sofa-outline",
        "sequence": [{"action": "light.turn_on", "target": {"entity_id": "light.living_room_living_room"},
                      "data": {"color_temp_kelvin": 2202, "brightness_pct": 30, "transition": 4}}],
    },
    # Cosy scene for the bedroom only (very warm, low).
    "bedroom_relax": {
        "alias": "Bedroom relax", "icon": "mdi:bed",
        "sequence": [{"action": "light.turn_on", "target": {"entity_id": "light.bedroom_bedroom"},
                      "data": {"color_temp_kelvin": 2000, "brightness_pct": 20, "transition": 4}}],
    },
    # Gaming: office ceiling off, Play bars + backlights to a purple bias-light glow. Also disables
    # work-lighting so work-mode can't fight it (re-armed 04:00 next weekday).
    "gaming_mode": {
        "alias": "Gaming mode", "icon": "mdi:gamepad-variant",
        "sequence": [{"action": "input_boolean.turn_off", "target": {"entity_id": "input_boolean.work_lighting"}},
                     {"action": "light.turn_off", "target": {"entity_id": "light.office_office_light"},
                      "data": {"transition": 2}},
                     {"action": "light.turn_on",
                      "target": {"entity_id": ["light.office_hue_play_1", "light.office_hue_play_2", "light.office_backlights"]},
                      "data": {"rgb_color": [150, 50, 230], "brightness_pct": 55, "transition": 2}}],
    },
}

# Reference export of the UI/config helpers (zones + persons). These live in HA's registry;
# this is the human-readable, diffable record. zone.home comes from core config, not listed here.
helpers = {
    "zone": [
        {"name": "Macclesfield Train Station", "latitude": 53.25944064320947, "longitude": -2.1222772381034076,
         "radius": 40, "icon": "mdi:map-marker", "passive": False},
        {"name": "Doncaster", "latitude": 53.51115414503215, "longitude": -1.135862684295688,
         "radius": 3312, "icon": "mdi:map-marker", "passive": False},
        {"name": "London Office", "latitude": 51.52117351989759, "longitude": -0.0809378516281356,
         "radius": 55, "icon": "mdi:office-building", "passive": False},
    ],
    "person": [
        {"name": "Alex Jenkinson", "device_trackers": ["device_tracker.alexs_iphone"]},
        {"name": "frigate", "device_trackers": []},
    ],
    # Toggles. Vitamins: reset off at 04:00 by its automation. Work lighting: master enable for the
    # WFH circadian automations. Work movement nudge: enables the workday Play-bar nudge.
    "input_boolean": [
        {"name": "Vitamins taken", "icon": "mdi:pill"},
        {"name": "Work lighting", "icon": "mdi:desk-lamp", "initial": True},
        {"name": "Work movement nudge", "icon": "mdi:seat-recline-normal", "initial": True},
    ],
    # Tunable times for the WFH lighting automations (edit on the dashboard without touching YAML).
    "input_datetime": [
        {"name": "Work start", "icon": "mdi:clock-start", "has_time": True, "has_date": False, "initial": "08:00:00"},
        {"name": "Work end", "icon": "mdi:clock-end", "has_time": True, "has_date": False, "initial": "17:00:00"},
        {"name": "Bedroom wake time", "icon": "mdi:weather-sunset-up", "has_time": True, "has_date": False, "initial": "07:40:00"},
        {"name": "Bedroom wind down", "icon": "mdi:weather-night", "has_time": True, "has_date": False, "initial": "21:30:00"},
        # Litter: stamped = now by "Litter: record emptied" when the waste bin clears. Drives the
        # days-since counter and the predicted-full date.
        {"name": "Litter last emptied", "icon": "mdi:delete-clock", "has_time": True, "has_date": True, "initial": "2026-11-20 22:00:00"},
    ],
    # Adaptive estimate of how many days the litter waste bin takes to fill. Starts at 5 and is
    # self-calibrated by "Litter: learn fill interval" each time the bin reports full (2:1 smoothing).
    # Energy: month-to-date spend + monthly budget feed the projected-bill run-rate.
    "input_number": [
        {"name": "Litter fill days", "icon": "mdi:calendar-clock", "min": 1, "max": 30, "step": 0.5,
         "initial": 5, "mode": "box", "unit_of_measurement": "d"},
        {"name": "Energy month to date", "icon": "mdi:cash-multiple", "min": 0, "max": 2000, "step": 0.01,
         "initial": 8.54, "mode": "box", "unit_of_measurement": "GBP"},
        {"name": "Energy monthly budget", "icon": "mdi:target", "min": 0, "max": 2000, "step": 5,
         "initial": 250, "mode": "box", "unit_of_measurement": "GBP"},
        # Daily step goal (gentle default, raise as it gets easy). Drives the move-goal tracker + nudge.
        {"name": "Step goal", "icon": "mdi:shoe-print", "min": 1000, "max": 30000, "step": 500,
         "initial": 6000, "mode": "box", "unit_of_measurement": "steps"},
        # Weight goals (kg). target = near-term, ideal = stretch, start = baseline for "lost so far".
        {"name": "Weight target", "icon": "mdi:scale-bathroom", "min": 40, "max": 200, "step": 0.1,
         "initial": 85, "mode": "box", "unit_of_measurement": "kg"},
        {"name": "Weight ideal", "icon": "mdi:scale-bathroom", "min": 40, "max": 200, "step": 0.1,
         "initial": 80, "mode": "box", "unit_of_measurement": "kg"},
        {"name": "Weight start", "icon": "mdi:flag-checkered", "min": 40, "max": 200, "step": 0.1,
         "initial": 93.5, "mode": "box", "unit_of_measurement": "kg"},
    ],
    # Days accrued into the energy month-to-date (run-rate denominator). Reset monthly.
    "counter": [
        {"name": "Energy days accrued", "icon": "mdi:calendar-range", "initial": 1, "step": 1, "minimum": 0},
    ],
    # Per-cat "last seen" = timestamp of each cat's most recent litter-tray use. The PetKit
    # tray weight-identifies the individual; Frigate only ever sees a generic "cat". Template
    # helpers (device_class timestamp -> tiles render "X ago"). The litter_* ones forecast the bin.
    "template": [
        {"name": "Misty last seen", "device_class": "timestamp",
         "state": "{{ ([states.sensor.misty_latest_weight.last_changed, states.sensor.misty_last_use_duration.last_changed] | max).isoformat() }}"},
        {"name": "Bella last seen", "device_class": "timestamp",
         "state": "{{ ([states.sensor.bella_latest_weight.last_changed, states.sensor.bella_last_use_duration.last_changed] | max).isoformat() }}"},
        {"name": "Leo last seen", "device_class": "timestamp",
         "state": "{{ ([states.sensor.leo_latest_weight.last_changed, states.sensor.leo_last_use_duration.last_changed] | max).isoformat() }}"},
        {"name": "Litter days since emptied", "unit_of_measurement": "d",
         "state": "{{ ((now().timestamp() - state_attr('input_datetime.litter_last_emptied','timestamp') | float(now().timestamp())) / 86400) | round(1) }}"},
        {"name": "Litter predicted full", "device_class": "timestamp",
         "state": "{{ (as_datetime(state_attr('input_datetime.litter_last_emptied','timestamp') | float(now().timestamp()) + states('input_number.litter_fill_days') | float(5) * 86400) | as_local).isoformat() }}"},
        # Projected monthly bill = (month-to-date / days accrued) * days in the current month.
        {"name": "Energy projected bill", "device_class": "monetary", "unit_of_measurement": "GBP",
         "state": "{% set mtd = states('input_number.energy_month_to_date')|float(0) %}{% set days = states('counter.energy_days_accrued')|int(1) %}{% set nm = (now().replace(day=28)+timedelta(days=4)).replace(day=1) %}{% set dim = (nm - timedelta(days=1)).day %}{{ ((mtd / ([days,1]|max)) * dim) | round(2) }}"},
        # Move goal: steps left to the daily goal, and progress % (for the gauge).
        {"name": "Steps to goal", "unit_of_measurement": "steps",
         "state": "{{ [states('input_number.step_goal')|int(6000) - states('sensor.alexs_iphone_steps')|int(0), 0] | max }}"},
        {"name": "Step goal progress", "unit_of_measurement": "%",
         "state": "{{ [ (states('sensor.alexs_iphone_steps')|int(0) / ([states('input_number.step_goal')|int(6000),1]|max) * 100) | round, 100] | min }}"},
        # Weight: kg still to go to target/ideal, and kg lost since the baseline. Source = Apple Health.
        {"name": "Weight to target", "unit_of_measurement": "kg",
         "state": "{{ (states('sensor.alexs_iphone_weight')|float(0) - states('input_number.weight_target')|float(85)) | round(1) }}"},
        {"name": "Weight to ideal", "unit_of_measurement": "kg",
         "state": "{{ (states('sensor.alexs_iphone_weight')|float(0) - states('input_number.weight_ideal')|float(80)) | round(1) }}"},
        {"name": "Weight lost", "unit_of_measurement": "kg",
         "state": "{{ (states('input_number.weight_start')|float(0) - states('sensor.alexs_iphone_weight')|float(0)) | round(1) }}"},
    ],
    # Template binary_sensors: litter fill-due, and projected bill over budget.
    "template_binary_sensor": [
        {"name": "Litter fill due soon", "device_class": "problem",
         "state": "{{ not is_state('binary_sensor.litter_tray_wastebin','on') and (state_attr('input_datetime.litter_last_emptied','timestamp') | float(now().timestamp()) + states('input_number.litter_fill_days') | float(5) * 86400) - now().timestamp() < 86400 }}"},
        {"name": "Energy over budget", "device_class": "problem",
         "state": "{{ states('sensor.energy_projected_bill')|float(0) > states('input_number.energy_monthly_budget')|float(999999) }}"},
        {"name": "Step goal met",
         "state": "{{ states('sensor.alexs_iphone_steps')|int(0) >= states('input_number.step_goal')|int(6000) }}"},
    ],
}

# Energy Dashboard preferences (HA .storage/energy — registry-managed, restored
# by the HA backup tarball). Diffable reference so a rebuild can re-enter them via
# Settings > Dashboards > Energy, or the energy/save_prefs API. Consumption +
# cost sensors come from the Octopus (BottlecapDave) integration.
energy_dashboard = {
    "energy_sources": [
        {"type": "grid", "cost_adjustment_day": 0,
         "stat_energy_from": "sensor.octopus_energy_electricity_19m0059512_1610012030180_previous_accumulative_consumption",
         "stat_cost": "sensor.octopus_energy_electricity_19m0059512_1610012030180_previous_accumulative_cost"},
        {"type": "gas",
         "stat_energy_from": "sensor.octopus_energy_gas_e6s17297892061_9384989210_previous_accumulative_consumption_kwh",
         "stat_cost": "sensor.octopus_energy_gas_e6s17297892061_9384989210_previous_accumulative_cost"},
    ],
    "device_consumption": [],
}

hdr = ("# Deployed live via HA-MCP and committed here as the source of truth.\n"
       "# Faithful copy of the HA automations; drop into /config/automations.yaml on a rebuild\n"
       "# (or just restore the HA backup tarball). See README.md.\n")
with open(OUT / "automations.yaml", "w") as f:
    f.write(hdr)
    yaml.safe_dump(automations, f, sort_keys=False, default_flow_style=False, allow_unicode=True, width=120)

with open(OUT / "helpers.yaml", "w") as f:
    f.write("# Reference export of HA zones + persons (registry-managed). Diffable record, not auto-loaded.\n")
    yaml.safe_dump(helpers, f, sort_keys=False, default_flow_style=False, allow_unicode=True, width=120)

with open(OUT / "energy-dashboard.yaml", "w") as f:
    f.write("# Reference export of the HA Energy Dashboard prefs (.storage/energy, registry-managed).\n"
            "# Re-apply on rebuild via Settings > Dashboards > Energy, or the energy/save_prefs API.\n")
    yaml.safe_dump(energy_dashboard, f, sort_keys=False, default_flow_style=False, allow_unicode=True, width=120)

with open(OUT / "scripts.yaml", "w") as f:
    f.write("# Deployed live via HA-MCP and committed here as source of truth.\n"
            "# Faithful copy of the HA scripts; drop into /config/scripts.yaml on a rebuild.\n")
    yaml.safe_dump(scripts, f, sort_keys=False, default_flow_style=False, allow_unicode=True, width=120)

print("wrote:", sorted(p.name for p in OUT.iterdir()))
