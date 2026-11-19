#!/usr/bin/env python3
"""Generate the glow-up HA dashboard (home.json) — Bubble Card + Mushroom + mini-graph + card-mod.
Hub-style Home with room pop-ups; polished Lights/Security/Media/Cats/Phone."""
import json, pathlib

OUT = pathlib.Path("/home/claude/home-server/configs/homeassistant/dashboards/home.json")

def bb(**k):           # bubble-card
    d = {"type": "custom:bubble-card"}; d.update(k); return d
def mush(t, **k):      # mushroom-<t>-card
    d = {"type": f"custom:mushroom-{t}-card"}; d.update(k); return d
def col(c, card):      # set grid_options columns (of 12) in a sections grid
    card = dict(card); card.setdefault("grid_options", {})["columns"] = c; return card
def heading(txt, icon=None):
    h = {"type": "heading", "heading": txt, "heading_style": "title"}
    if icon: h["icon"] = icon
    return h
def subheading(txt, icon=None):
    h = {"type": "heading", "heading": txt, "heading_style": "subtitle"}
    if icon: h["icon"] = icon
    return h
def section(*cards):
    return {"type": "grid", "cards": [c for c in cards if c]}

# ---- Bubble helpers ----
def room_button(name, icon, link, entity):
    return bb(card_type="button", button_type="name", name=name, icon=icon, entity=entity,
              show_state=True, scrolling_effect=False,
              button_action={"tap_action": {"action": "navigate", "navigation_path": link}},
              card_layout="large")
def slider(entity, name=None, icon=None):
    d = bb(card_type="button", button_type="slider", entity=entity)
    if name: d["name"] = name
    if icon: d["icon"] = icon
    return d
def switch_btn(entity, name=None, icon=None):
    d = bb(card_type="button", button_type="switch", entity=entity)
    if name: d["name"] = name
    if icon: d["icon"] = icon
    return d
def sep(name, icon):
    return bb(card_type="separator", name=name, icon=icon)
def popup(hsh, name, icon, cards, entity=None):
    d = bb(card_type="pop-up", hash=hsh, name=name, icon=icon, cards=cards)
    if entity: d["entity"] = entity
    return d

# ---- scene select as a native tile with the select feature ----
def scene_tile(entity, name):
    return {"type": "tile", "entity": entity, "name": name, "icon": "mdi:palette",
            "features": [{"type": "select-options"}], "features_position": "bottom"}
def media_tile(entity, name):
    return mush("media-player", entity=entity, name=name,
                media_controls=["play_pause_stop", "previous", "next"],
                volume_controls=["volume_buttons"], use_media_info=True,
                collapsible_controls=True)
def cam(entity, name):
    return {"type": "picture-entity", "entity": entity, "name": name,
            "show_state": False, "show_name": True, "camera_view": "auto",
            "grid_options": {"columns": 6}}

# =====================================================================
# ROOM POP-UPS
# =====================================================================
pop_living = popup("#living-room", "Living Room", "mdi:sofa", [
    slider("light.living_room_living_room", "Living Room", "mdi:floor-lamp"),
    scene_tile("select.living_room_living_room_scene", "Scene"),
    media_tile("media_player.living_room_alexa", "Living Room"),
    {"type": "tile", "entity": "binary_sensor.living_room_alexa_motion", "name": "Motion"},
    cam("camera.living_room_cam_living_room", "Living Room"),
], entity="light.living_room_living_room")

pop_bedroom = popup("#bedroom", "Bedroom", "mdi:bed", [
    slider("light.bedroom_bedroom", "Bedroom", "mdi:ceiling-light"),
    scene_tile("select.bedroom_bedroom_scene", "Scene"),
    media_tile("media_player.bedroom_alexa", "Bedroom"),
    {"type": "tile", "entity": "binary_sensor.bedroom_alexa_motion", "name": "Motion"},
    cam("camera.bedroom_cam_bedroom", "Bedroom"),
], entity="light.bedroom_bedroom")

pop_office = popup("#office", "Office", "mdi:desk", [
    slider("light.office_office", "Office", "mdi:desk-lamp"),
    scene_tile("select.office_office_scene", "Scene"),
    sep("Accents", "mdi:led-strip-variant"),
    col(4, switch_btn("light.office_backlights", "Backlight", "mdi:television-ambient-light")),
    col(4, switch_btn("light.office_hue_play_1", "Play 1", "mdi:lightbulb")),
    col(4, switch_btn("light.office_hue_play_2", "Play 2", "mdi:lightbulb")),
    media_tile("media_player.office_alexa", "Office"),
], entity="light.office_office")

pop_upstairs = popup("#upstairs", "Upstairs", "mdi:stairs", [
    slider("light.upstairs", "Upstairs", "mdi:light-recessed"),
    scene_tile("select.upstairs_scene", "Scene"),
    media_tile("media_player.upstairs", "Upstairs"),
], entity="light.upstairs")

# =====================================================================
# VIEW: HOME
# =====================================================================
home = {
    "title": "Home", "path": "home", "type": "sections", "icon": "mdi:home-heart",
    "sections": [
        section(
            col(12, mush("template",
                primary="{% set h = now().hour %}{% if h < 5 %}Still up, Alex{% elif h < 12 %}Good morning, Alex{% elif h < 18 %}Good afternoon, Alex{% else %}Good evening, Alex{% endif %}",
                secondary="{{ now().strftime('%A %-d %B') }}  ·  {{ states('weather.home') | replace('_',' ') | title }}, {{ state_attr('weather.home','temperature') | round }}°",
                icon="mdi:hand-wave", icon_color="amber",
                card_mod={"style": "ha-card { background: none; border: none; box-shadow: none; } .primary { font-size: 1.5rem !important; font-weight: 600 !important; }"})),
            col(12, mush("chips", alignment="start", chips=[
                {"type": "entity", "entity": "person.alex_jenkinson", "icon_color": "blue", "content_info": "state"},
                {"type": "weather", "entity": "weather.home", "show_conditions": True, "show_temperature": True},
                {"type": "entity", "entity": "sensor.hue_motion_sensor_temperature", "icon": "mdi:home-thermometer", "icon_color": "orange"},
                {"type": "entity", "entity": "vacuum.robovac", "icon": "mdi:robot-vacuum", "icon_color": "teal"},
                {"type": "entity", "entity": "sensor.alexs_iphone_steps", "icon": "mdi:shoe-print", "icon_color": "green"},
            ])),
        ),
        section(
            heading("Rooms", "mdi:floor-plan"),
            col(6, room_button("Living Room", "mdi:sofa", "#living-room", "light.living_room_living_room")),
            col(6, room_button("Bedroom", "mdi:bed", "#bedroom", "light.bedroom_bedroom")),
            col(6, room_button("Office", "mdi:desk", "#office", "light.office_office")),
            col(6, room_button("Upstairs", "mdi:stairs", "#upstairs", "light.upstairs")),
        ),
        section(
            heading("Quick", "mdi:flash"),
            col(6, switch_btn("switch.adaptive_lighting_adaptive_lighting", "Adaptive Lighting", "mdi:theme-light-dark")),
            col(6, bb(card_type="button", button_type="name", name="All lights off", icon="mdi:lightbulb-group-off",
                      button_action={"tap_action": {"action": "call-service", "service": "light.turn_off",
                                                     "target": {"entity_id": "all"}}})),
        ),
        section(
            heading("Today", "mdi:calendar-today"),
            col(6, {"type": "tile", "entity": "sensor.waste_collection_schedule_mixed_recycling",
                    "name": "Recycling", "icon": "mdi:recycle", "color": "green"}),
            col(6, {"type": "tile", "entity": "sensor.waste_collection_schedule_general_waste",
                    "name": "General waste", "icon": "mdi:trash-can", "color": "grey"}),
            col(6, {"type": "tile", "entity": "vacuum.robovac", "name": "RoboVac", "icon": "mdi:robot-vacuum",
                    "features": [{"type": "vacuum-commands", "commands": ["start_pause", "stop", "return_home"]}]}),
            col(6, {"type": "tile", "entity": "binary_sensor.litter_tray_wastebin",
                    "name": "Litter bin", "icon": "mdi:delete-alert"}),
        ),
        section(
            heading("Now", "mdi:cctv"),
            cam("camera.living_room_cam_living_room", "Living Room"),
            cam("camera.bedroom_cam_bedroom", "Bedroom"),
        ),
        # pop-ups (render nothing inline)
        section(pop_living, pop_bedroom, pop_office, pop_upstairs),
    ],
}

# =====================================================================
# VIEW: LIGHTS
# =====================================================================
lights = {
    "title": "Lights", "path": "lights", "type": "sections", "icon": "mdi:lightbulb-group",
    "sections": [
        section(
            heading("Rooms", "mdi:floor-plan"),
            col(6, slider("light.living_room_living_room", "Living Room", "mdi:sofa")),
            col(6, slider("light.bedroom_bedroom", "Bedroom", "mdi:bed")),
            col(6, slider("light.office_office", "Office", "mdi:desk")),
            col(6, slider("light.upstairs", "Upstairs", "mdi:stairs")),
        ),
        section(
            heading("Office accents", "mdi:led-strip-variant"),
            col(4, switch_btn("light.office_backlights", "Backlight", "mdi:television-ambient-light")),
            col(4, switch_btn("light.office_hue_play_1", "Play 1", "mdi:lightbulb")),
            col(4, switch_btn("light.office_hue_play_2", "Play 2", "mdi:lightbulb")),
        ),
        section(
            heading("Scenes", "mdi:palette"),
            col(6, scene_tile("select.living_room_living_room_scene", "Living Room")),
            col(6, scene_tile("select.bedroom_bedroom_scene", "Bedroom")),
            col(6, scene_tile("select.office_office_scene", "Office")),
            col(6, scene_tile("select.upstairs_scene", "Upstairs")),
        ),
        section(
            heading("Adaptive", "mdi:theme-light-dark"),
            col(6, switch_btn("switch.adaptive_lighting_adaptive_lighting", "Adaptive Lighting", "mdi:theme-light-dark")),
            col(6, switch_btn("switch.adaptive_lighting_adaptive_lighting_sleep_mode", "Sleep mode", "mdi:power-sleep")),
        ),
    ],
}

# =====================================================================
# VIEW: SECURITY
# =====================================================================
security = {
    "title": "Security", "path": "security", "type": "sections", "icon": "mdi:shield-home",
    "sections": [
        section(
            heading("Doorbell", "mdi:doorbell-video"),
            col(12, {"type": "picture-entity", "entity": "camera.doorbell", "name": "Doorbell",
                     "camera_view": "auto", "show_state": False}),
            col(4, {"type": "tile", "entity": "binary_sensor.doorbell_ringing", "name": "Ringing", "icon": "mdi:bell-ring"}),
            col(4, {"type": "tile", "entity": "binary_sensor.doorbell_person", "name": "Person", "icon": "mdi:account"}),
            col(4, {"type": "tile", "entity": "sensor.doorbell_battery", "name": "Battery", "icon": "mdi:battery"}),
        ),
        section(
            heading("Cameras", "mdi:cctv"),
            cam("camera.living_room_cam_living_room", "Living Room"),
            cam("camera.living_room_cam_kitchen", "Kitchen"),
            cam("camera.bedroom_cam_bedroom", "Bedroom"),
            cam("camera.utility_cam_basement", "Basement"),
        ),
        section(
            heading("Presence", "mdi:account-eye"),
            col(4, {"type": "tile", "entity": "person.alex_jenkinson", "name": "Alex"}),
            col(4, {"type": "tile", "entity": "binary_sensor.living_room_cam_living_room_person_occupancy", "name": "Living Room"}),
            col(4, {"type": "tile", "entity": "binary_sensor.living_room_cam_kitchen_person_occupancy", "name": "Kitchen"}),
            col(4, {"type": "tile", "entity": "binary_sensor.bedroom_cam_bedroom_person_occupancy", "name": "Bedroom"}),
            col(4, {"type": "tile", "entity": "binary_sensor.utility_cam_basement_person_occupancy", "name": "Basement"}),
        ),
        section(
            heading("Motion", "mdi:motion-sensor"),
            col(4, {"type": "tile", "entity": "binary_sensor.hue_motion_sensor_motion", "name": "Hue"}),
            col(4, {"type": "tile", "entity": "binary_sensor.living_room_alexa_motion", "name": "Living Room"}),
            col(4, {"type": "tile", "entity": "binary_sensor.bedroom_alexa_motion", "name": "Bedroom"}),
        ),
    ],
}

# =====================================================================
# VIEW: MEDIA
# =====================================================================
media = {
    "title": "Media", "path": "media", "type": "sections", "icon": "mdi:speaker-multiple",
    "sections": [
        section(
            heading("Speakers", "mdi:speaker"),
            col(12, media_tile("media_player.everywhere", "Everywhere")),
            col(6, media_tile("media_player.living_room_alexa", "Living Room")),
            col(6, media_tile("media_player.bedroom_alexa", "Bedroom")),
            col(6, media_tile("media_player.office_alexa", "Office")),
            col(6, media_tile("media_player.upstairs", "Upstairs")),
        ),
        section(
            heading("Do not disturb", "mdi:minus-circle"),
            col(4, switch_btn("switch.living_room_alexa_do_not_disturb", "Living Room", "mdi:minus-circle")),
            col(4, switch_btn("switch.bedroom_alexa_do_not_disturb", "Bedroom", "mdi:minus-circle")),
            col(4, switch_btn("switch.office_alexa_do_not_disturb", "Office", "mdi:minus-circle")),
        ),
    ],
}

# =====================================================================
# VIEW: CATS  (was "Poe")
# =====================================================================
cats = {
    "title": "Cats", "path": "cats", "type": "sections", "icon": "mdi:cat",
    "sections": [
        section(
            heading("Litter tray", "mdi:cat"),
            col(6, {"type": "tile", "entity": "binary_sensor.litter_tray_wastebin", "name": "Waste bin", "icon": "mdi:delete-alert", "color": "red"}),
            col(6, {"type": "tile", "entity": "sensor.litter_tray_state", "name": "State", "icon": "mdi:robot"}),
            col(6, {"type": "gauge", "entity": "sensor.litter_tray_litter_level", "name": "Litter level",
                    "min": 0, "max": 100, "severity": {"green": 40, "yellow": 20, "red": 0}}),
            col(6, {"type": "tile", "entity": "sensor.litter_tray_last_used_by", "name": "Last used by", "icon": "mdi:paw"}),
            col(6, {"type": "tile", "entity": "binary_sensor.litter_tray_litter", "name": "Litter low", "icon": "mdi:cup"}),
            col(6, {"type": "tile", "entity": "sensor.litter_tray_n50_odor_eliminator", "name": "Odor N50", "icon": "mdi:air-filter"}),
        ),
        section(
            heading("The cats", "mdi:cat"),
            col(4, mush("template", entity="sensor.misty_latest_weight", primary="Misty",
                        secondary="{{ states('sensor.misty_latest_weight') }} kg",
                        picture="{{ state_attr('sensor.misty_latest_weight','entity_picture') }}")),
            col(4, mush("template", entity="sensor.bella_latest_weight", primary="Bella",
                        secondary="{{ states('sensor.bella_latest_weight') }} kg",
                        picture="{{ state_attr('sensor.bella_latest_weight','entity_picture') }}")),
            col(4, mush("template", entity="sensor.leo_latest_weight", primary="Leo",
                        secondary="{{ states('sensor.leo_latest_weight') }} kg",
                        picture="{{ state_attr('sensor.leo_latest_weight','entity_picture') }}")),
        ),
        section(
            heading("Controls", "mdi:gesture-tap-button"),
            col(3, switch_btn("switch.litter_tray_power", "Power", "mdi:power")),
            col(3, switch_btn("switch.litter_tray_auto_cleaning", "Auto clean", "mdi:broom")),
            col(3, bb(card_type="button", button_type="name", name="Clean now", icon="mdi:broom",
                      button_action={"tap_action": {"action": "perform-action", "perform_action": "button.press", "target": {"entity_id": "button.litter_tray_start_resume_cleaning"}}})),
            col(3, bb(card_type="button", button_type="name", name="Deodorize", icon="mdi:spray",
                      button_action={"tap_action": {"action": "perform-action", "perform_action": "button.press", "target": {"entity_id": "button.litter_tray_odor_removal"}}})),
        ),
    ],
}

# =====================================================================
# VIEW: PHONE
# =====================================================================
phone = {
    "title": "Phone", "path": "phone", "type": "sections", "icon": "mdi:cellphone",
    "sections": [
        section(
            heading("Alex's iPhone", "mdi:cellphone"),
            col(6, {"type": "tile", "entity": "sensor.alexs_iphone_battery_level", "name": "Battery", "icon": "mdi:battery"}),
            col(6, {"type": "tile", "entity": "sensor.alexs_iphone_activity", "name": "Activity", "icon": "mdi:run"}),
            col(12, {"type": "tile", "entity": "sensor.alexs_iphone_geocoded_location", "name": "Where", "icon": "mdi:map-marker"}),
        ),
        section(
            heading("Steps", "mdi:shoe-print"),
            col(12, {"type": "custom:mini-graph-card", "entities": [{"entity": "sensor.alexs_iphone_steps", "name": "Steps"}],
                     "name": "Steps", "hours_to_show": 168, "aggregate_func": "max", "group_by": "date",
                     "show": {"graph": "bar"}, "color_thresholds": [{"value": 0, "color": "#44bba4"}]}),
        ),
        section(
            heading("Location", "mdi:map"),
            col(12, {"type": "map", "entities": ["device_tracker.alexs_iphone"], "default_zoom": 11, "hours_to_show": 0}),
        ),
    ],
}

config = {"views": [home, lights, security, media, cats, phone]}

OUT.write_text(json.dumps(config, indent=2, ensure_ascii=False))
print("wrote", OUT, "-", len(json.dumps(config)), "bytes,", len(config["views"]), "views")
# sanity: reparse
json.loads(OUT.read_text())
print("JSON valid")
