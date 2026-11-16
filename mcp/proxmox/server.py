#!/usr/bin/env python3
"""Minimal, auditable Proxmox MCP server for the home-server stack.

Exposes READ + guest-LIFECYCLE tools over the Proxmox VE API, authenticated with the
scoped API token from configs/lxc/stage-a-host-setup.sh. Deliberately has NO guest
shell, NO node shell, and NO guest creation — those stay in the repo's scripts. The
whole server is this one file so you can read every tool before trusting it.

Config via env, or a gitignored env file (default mcp/proxmox/proxmox.env, or set
PROXMOX_ENV to point elsewhere — e.g. a second file for NUC-2):
  PROXMOX_HOST          e.g. 192.168.1.2 (NUC-1)
  PROXMOX_PORT          default 8006
  PROXMOX_TOKEN_ID      e.g. claude@pve!automation
  PROXMOX_TOKEN_SECRET  the secret printed once by stage-a
  PROXMOX_VERIFY_SSL    "false" (self-signed, default), "true", or a path to a CA bundle
  PROXMOX_READONLY      "true" refuses every power/snapshot write (extra belt-and-braces)

Run as an MCP server:   python server.py           (stdio transport)
Check connectivity:     python server.py --selftest (prints the node list and exits)
"""
import os
import sys

import requests
import urllib3
from mcp.server.fastmcp import FastMCP

# ---- config -----------------------------------------------------------------
_envfile = os.environ.get("PROXMOX_ENV") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "proxmox.env")
if os.path.exists(_envfile):
    for _l in open(_envfile):
        _l = _l.strip()
        if _l and not _l.startswith("#") and "=" in _l:
            _k, _v = _l.split("=", 1)
            os.environ.setdefault(_k.strip(), _v.strip())  # real env wins (lets NUC-2 override)

HOST = os.environ.get("PROXMOX_HOST")
PORT = os.environ.get("PROXMOX_PORT", "8006")
TOKEN_ID = os.environ.get("PROXMOX_TOKEN_ID")
TOKEN_SECRET = os.environ.get("PROXMOX_TOKEN_SECRET")
VERIFY = os.environ.get("PROXMOX_VERIFY_SSL", "false")
READONLY = os.environ.get("PROXMOX_READONLY", "false").lower() == "true"

if not all([HOST, TOKEN_ID, TOKEN_SECRET]):
    raise SystemExit("set PROXMOX_HOST, PROXMOX_TOKEN_ID, PROXMOX_TOKEN_SECRET (env or proxmox.env)")

BASE = f"https://{HOST}:{PORT}/api2/json"
if VERIFY.lower() in ("false", "0", "no"):
    VERIFY_ARG = False
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
elif VERIFY.lower() in ("true", "1", "yes"):
    VERIFY_ARG = True
else:
    VERIFY_ARG = VERIFY  # a CA bundle path
HEADERS = {"Authorization": f"PVEAPIToken={TOKEN_ID}={TOKEN_SECRET}"}

mcp = FastMCP("proxmox-home-server")


def _req(method: str, path: str, **kw):
    r = requests.request(method, f"{BASE}{path}", headers=HEADERS,
                         verify=VERIFY_ARG, timeout=15, **kw)
    r.raise_for_status()
    return r.json().get("data") if r.text.strip() else None


def _guard_write():
    if READONLY:
        raise PermissionError("PROXMOX_READONLY is set — write refused.")


def _check_kind(kind: str):
    if kind not in ("lxc", "qemu"):
        raise ValueError("kind must be 'lxc' (container) or 'qemu' (VM)")


# ---- read tools -------------------------------------------------------------
@mcp.tool()
def list_nodes() -> list:
    """List cluster nodes with status, CPU and memory."""
    return _req("GET", "/nodes")


@mcp.tool()
def cluster_resources(kind: str = "") -> list:
    """Cluster-wide resources. kind: '' (all), 'vm', 'storage', or 'node'."""
    return _req("GET", "/cluster/resources" + (f"?type={kind}" if kind else ""))


@mcp.tool()
def list_guests(node: str) -> dict:
    """List LXC containers and QEMU VMs on a node, with run state."""
    return {"lxc": _req("GET", f"/nodes/{node}/lxc"),
            "qemu": _req("GET", f"/nodes/{node}/qemu")}


@mcp.tool()
def guest_status(node: str, vmid: int, kind: str) -> dict:
    """Current status + runtime of one guest. kind: 'lxc' or 'qemu'."""
    _check_kind(kind)
    return _req("GET", f"/nodes/{node}/{kind}/{vmid}/status/current")


@mcp.tool()
def guest_config(node: str, vmid: int, kind: str) -> dict:
    """The stored config of one guest (cores, memory, mounts, net). kind: 'lxc' or 'qemu'."""
    _check_kind(kind)
    return _req("GET", f"/nodes/{node}/{kind}/{vmid}/config")


@mcp.tool()
def snapshot_list(node: str, vmid: int, kind: str) -> list:
    """List snapshots of a guest."""
    _check_kind(kind)
    return _req("GET", f"/nodes/{node}/{kind}/{vmid}/snapshot")


@mcp.tool()
def task_status(node: str, upid: str) -> dict:
    """Status of a task by UPID (returned from a power/snapshot action)."""
    return _req("GET", f"/nodes/{node}/tasks/{upid}/status")


@mcp.tool()
def node_status(node: str) -> dict:
    """Node resource usage: cpu, memory, uptime, load average."""
    return _req("GET", f"/nodes/{node}/status")


# ---- lifecycle tools (writes; blocked by PROXMOX_READONLY) -------------------
@mcp.tool()
def guest_power(node: str, vmid: int, kind: str, action: str) -> str:
    """Power action on a guest. action: start|stop|shutdown|reboot. kind: lxc|qemu.
    Returns the task UPID — poll it with task_status. ('stop' is a hard pull;
    'shutdown' asks the guest first.)"""
    _check_kind(kind)
    if action not in ("start", "stop", "shutdown", "reboot"):
        raise ValueError("action must be start|stop|shutdown|reboot")
    _guard_write()
    return _req("POST", f"/nodes/{node}/{kind}/{vmid}/status/{action}")


@mcp.tool()
def snapshot_create(node: str, vmid: int, kind: str, name: str, description: str = "") -> str:
    """Create a snapshot of a guest. Returns the task UPID."""
    _check_kind(kind)
    _guard_write()
    return _req("POST", f"/nodes/{node}/{kind}/{vmid}/snapshot",
                data={"snapname": name, "description": description})


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        import json
        print(json.dumps(list_nodes(), indent=2))
        sys.exit(0)
    mcp.run()
