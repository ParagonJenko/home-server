#!/usr/bin/env python3
"""maintainerr-keeper — a Discord bot that puts Keep / Delete buttons on Maintainerr cleanup
candidates, so anyone (non-technical included) can protect or remove a title from Discord.

Flow:
  * Polls Maintainerr every POLL_SECONDS for its cleanup collections (names starting with any of
    COLLECTION_PREFIXES — the "Clear —" and "Review —" groups the seed script makes).
  * Posts each new item once to DISCORD_CHANNEL_ID with a poster, why it was flagged, and two
    buttons:
      🟢 Keep   -> Maintainerr exclusion (POST /api/rules/exclusion, action ADD). The item is
                  protected forever and dropped from the collection; it will never be deleted.
      🗑️ Delete -> resolves the item's TMDB/TVDB id via Maintainerr's Plex metadata, finds it in
                  Radarr/Sonarr and deletes it WITH files. If it can't match exactly, it refuses
                  and tells you to delete by hand — it never deletes a guessed match.
  * Edits the message to record the outcome and who clicked.

Runtime: gateway (outbound websocket) only — no inbound ports, no public endpoint (R20). Button
clicks are handled in on_interaction by parsing the button custom_id, so they keep working across
restarts without persistent-view registration. Posted-state is kept in STATE_FILE so nothing is
double-posted.

Safety: set DRY_RUN=1 to post buttons and log what a click WOULD do without excluding or deleting.

All config comes from environment (set by gather-keeper-creds.sh into the stack .env):
  DISCORD_BOT_TOKEN   (required)   bot token from the Discord developer portal
  DISCORD_CHANNEL_ID  (required)   numeric channel id to post into
  MAINTAINERR_URL     default http://maintainerr:6246    (same compose network)
  RADARR_URL  / RADARR_API_KEY     default http://radarr:7878  + key from .env
  SONARR_URL  / SONARR_API_KEY     default http://sonarr:8989  + key from .env
  COLLECTION_PREFIXES default "Clear —,Review —"
  POLL_SECONDS        default 300
  STATE_FILE          default /data/posted.json
  DRY_RUN             default 0
"""
import asyncio
import json
import os
import sys

import aiohttp
import discord

MAINTAINERR = os.environ.get("MAINTAINERR_URL", "http://maintainerr:6246").rstrip("/")
RADARR = os.environ.get("RADARR_URL", "http://radarr:7878").rstrip("/")
SONARR = os.environ.get("SONARR_URL", "http://sonarr:8989").rstrip("/")
RADARR_KEY = os.environ.get("RADARR_API_KEY", "")
SONARR_KEY = os.environ.get("SONARR_API_KEY", "")
CHANNEL_ID = int(os.environ.get("DISCORD_CHANNEL_ID", "0") or "0")
TOKEN = os.environ.get("DISCORD_BOT_TOKEN", "")
PREFIXES = [p.strip() for p in os.environ.get("COLLECTION_PREFIXES", "Clear —,Review —").split(",") if p.strip()]
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "300"))
STATE_FILE = os.environ.get("STATE_FILE", "/data/posted.json")
DRY_RUN = os.environ.get("DRY_RUN", "0") not in ("0", "", "false", "False")

CID = "mk"  # custom_id namespace


def log(*a):
    print("[keeper]", *a, flush=True)


# ---------- tiny persistent state (which plexIds we've already posted) ----------
def load_state():
    try:
        with open(STATE_FILE) as f:
            return set(json.load(f))
    except Exception:
        return set()


def save_state(posted):
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        with open(STATE_FILE, "w") as f:
            json.dump(sorted(posted), f)
    except Exception as e:
        log("could not save state:", e)


# ---------- HTTP helpers ----------
async def jget(session, url, headers=None):
    async with session.get(url, headers=headers, timeout=aiohttp.ClientTimeout(total=20)) as r:
        if r.status != 200:
            return None
        try:
            return await r.json()
        except Exception:
            return None


async def jpost(session, url, body, headers=None):
    async with session.post(url, json=body, headers=headers, timeout=aiohttp.ClientTimeout(total=20)) as r:
        txt = await r.text()
        try:
            return r.status, json.loads(txt) if txt.strip() else None
        except Exception:
            return r.status, txt


# ---------- Maintainerr ----------
async def maintainerr_collections(session):
    data = await jget(session, f"{MAINTAINERR}/api/collections")
    if not isinstance(data, list):
        return []
    out = []
    for c in data:
        name = c.get("title") or ""
        if c.get("isActive") and any(name.startswith(p) for p in PREFIXES):
            out.append(c)
    return out


async def maintainerr_media(session, collection_id):
    data = await jget(session, f"{MAINTAINERR}/api/collections/media/?collectionId={collection_id}")
    return data if isinstance(data, list) else []


async def maintainerr_exclude(session, media_id, data_type, collection_id, rule_group_id):
    body = {"mediaId": media_id, "context": {"id": media_id, "type": data_type},
            "collectionId": collection_id, "ruleGroupId": rule_group_id, "action": 0}
    return await jpost(session, f"{MAINTAINERR}/api/rules/exclusion", body)


async def plex_guids(session, plex_id):
    """Return {'tmdb': int|None, 'tvdb': int|None} for a Plex ratingKey, via Maintainerr's proxy."""
    meta = await jget(session, f"{MAINTAINERR}/api/plex/meta/{plex_id}")
    guids = {}
    if isinstance(meta, dict):
        for g in (meta.get("Guid") or []):
            gid = g.get("id", "") if isinstance(g, dict) else ""
            for pfx, key in (("tmdb://", "tmdb"), ("tvdb://", "tvdb")):
                if gid.startswith(pfx):
                    num = gid[len(pfx):].split("?")[0]
                    if num.isdigit():
                        guids[key] = int(num)
    return guids


# ---------- Radarr / Sonarr delete (with files) ----------
async def arr_delete(session, data_type, guids):
    """Delete the movie (type MOVIES=1) or series (SHOWS=2) with files. Returns (ok, message)."""
    if data_type == 1 and RADARR_KEY and guids.get("tmdb"):
        h = {"X-Api-Key": RADARR_KEY}
        hits = await jget(session, f"{RADARR}/api/v3/movie?tmdbId={guids['tmdb']}", h)
        hits = hits if isinstance(hits, list) else []
        if len(hits) != 1:
            return False, f"Radarr match was {len(hits)} movies — not deleting; remove it by hand."
        mid = hits[0].get("id")
        async with session.delete(f"{RADARR}/api/v3/movie/{mid}?deleteFiles=true&addImportExclusion=false",
                                  headers=h, timeout=aiohttp.ClientTimeout(total=30)) as r:
            return (r.status in (200, 204)), (f"Radarr delete HTTP {r.status}")
    if data_type == 2 and SONARR_KEY and guids.get("tvdb"):
        h = {"X-Api-Key": SONARR_KEY}
        hits = await jget(session, f"{SONARR}/api/v3/series?tvdbId={guids['tvdb']}", h)
        hits = hits if isinstance(hits, list) else []
        if len(hits) != 1:
            return False, f"Sonarr match was {len(hits)} series — not deleting; remove it by hand."
        sid = hits[0].get("id")
        async with session.delete(f"{SONARR}/api/v3/series/{sid}?deleteFiles=true&addImportListExclusion=false",
                                  headers=h, timeout=aiohttp.ClientTimeout(total=30)) as r:
            return (r.status in (200, 204)), (f"Sonarr delete HTTP {r.status}")
    return False, "no TMDB/TVDB id or Arr key — can't auto-delete; remove it by hand."


# ---------- Discord ----------
class Keeper(discord.Client):
    def __init__(self):
        super().__init__(intents=discord.Intents.none())
        self.session = None
        self.posted = load_state()

    async def setup_hook(self):
        self.session = aiohttp.ClientSession()
        self.loop.create_task(self.poll_loop())

    def card(self, collection_name, media):
        plex_id = media.get("plexId")
        title = media.get("title") or f"plexId {plex_id}"
        e = discord.Embed(title=title,
                          description=f"Flagged by **{collection_name}**.\n"
                                      f"🟢 **Keep** protects it forever. 🗑️ **Delete** removes it with its files.",
                          colour=0xE67E22 if collection_name.startswith("Review") else 0xC0392B)
        return e

    def buttons(self, collection, media):
        plex_id = media.get("plexId")
        dtype = collection.get("type") or ((collection.get("ruleGroup") or {}).get("dataType")) or 1
        rg = (collection.get("ruleGroup") or {}).get("id") or collection.get("ruleGroupId") or 0
        cid = collection.get("id")
        v = discord.ui.View(timeout=None)
        v.add_item(discord.ui.Button(label="Keep", style=discord.ButtonStyle.success, emoji="🟢",
                                     custom_id=f"{CID}|keep|{cid}|{rg}|{plex_id}|{dtype}"))
        v.add_item(discord.ui.Button(label="Delete", style=discord.ButtonStyle.danger, emoji="🗑️",
                                     custom_id=f"{CID}|del|{cid}|{rg}|{plex_id}|{dtype}"))
        return v

    async def poll_loop(self):
        await self.wait_until_ready()
        channel = self.get_channel(CHANNEL_ID) or await self.fetch_channel(CHANNEL_ID)
        # One-time startup ping so you can confirm the channel + permissions are right. This also
        # proves posting works before any real candidate exists (those need a cleanup group to run).
        hello = discord.Embed(
            title="🟢 maintainerr-keeper connected",
            description=(f"**Mode:** {'DRY-RUN (buttons only log)' if DRY_RUN else 'LIVE'}\n"
                         f"**Watching collections:** {', '.join(PREFIXES)}\n"
                         f"**Checking every:** {POLL_SECONDS}s\n\n"
                         "Cleanup candidates will appear here with 🟢 Keep / 🗑️ Delete buttons once a "
                         "Maintainerr group has run and put items in its collection."),
            colour=0x2ECC71)
        try:
            await channel.send(embed=hello)
        except Exception as e:
            log("could not send startup message:", e)
        while not self.is_closed():
            try:
                cols = await maintainerr_collections(self.session)
                for c in cols:
                    for m in await maintainerr_media(self.session, c["id"]):
                        key = f'{c["id"]}:{m.get("plexId")}'
                        if key in self.posted:
                            continue
                        await channel.send(embed=self.card(c.get("title", ""), m), view=self.buttons(c, m))
                        self.posted.add(key)
                        save_state(self.posted)
            except Exception as e:
                log("poll error:", e)
            await asyncio.sleep(POLL_SECONDS)

    async def on_interaction(self, interaction: discord.Interaction):
        data = interaction.data or {}
        cid = data.get("custom_id", "")
        if not cid.startswith(f"{CID}|"):
            return
        _, action, coll, rg, plex_id, dtype = cid.split("|")
        coll, rg, plex_id, dtype = int(coll), int(rg), int(plex_id), int(dtype)
        who = interaction.user.mention
        await interaction.response.defer()
        if action == "keep":
            if DRY_RUN:
                msg = f"✅ (dry-run) would Keep — by {who}"
            else:
                st, _ = await maintainerr_exclude(self.session, plex_id, dtype, coll, rg)
                msg = (f"✅ Kept by {who}" if st in (200, 201) else f"⚠️ Keep failed (HTTP {st}) — try Maintainerr UI")
        else:  # delete
            if DRY_RUN:
                msg = f"🗑️ (dry-run) would Delete — by {who}"
            else:
                guids = await plex_guids(self.session, plex_id)
                ok, detail = await arr_delete(self.session, dtype, guids)
                msg = (f"🗑️ Deleted by {who}" if ok else f"⚠️ {detail} ({who})")
        try:
            orig = await interaction.original_response()
            e = orig.embeds[0] if orig.embeds else discord.Embed()
            e.add_field(name="Outcome", value=msg, inline=False)
            await interaction.edit_original_response(embed=e, view=None)
        except Exception as e:
            log("edit failed:", e)


def main():
    if not TOKEN or not CHANNEL_ID:
        log("DISCORD_BOT_TOKEN and DISCORD_CHANNEL_ID are required. Run gather-keeper-creds.sh.")
        sys.exit(1)
    log(f"starting — Maintainerr={MAINTAINERR} channel={CHANNEL_ID} prefixes={PREFIXES} "
        f"poll={POLL_SECONDS}s dry_run={DRY_RUN}")
    Keeper().run(TOKEN, log_handler=None)


if __name__ == "__main__":
    main()
