# Proxmox MCP server (home-grown)

A ~150-line MCP server that lets Claude drive Proxmox over its API with the **scoped
token** from `configs/lxc/stage-a-host-setup.sh`. Read + guest-lifecycle only — no
guest shell, no node shell, no guest creation (those stay in the repo's scripts). One
file (`server.py`); read it before trusting it.

## Tools

`list_nodes`, `cluster_resources`, `list_guests`, `guest_status`, `guest_config`,
`node_status`, `snapshot_list`, `task_status` (read) · `guest_power` (start/stop/
shutdown/reboot), `snapshot_create` (writes — set `PROXMOX_READONLY=true` to block).

## Install (on the machine that runs Claude)

```bash
cd mcp/proxmox
./setup.sh      # venv + deps + self-test, then prints the client-registration line
```

`setup.sh` does everything — no commands to type by hand. It needs `proxmox.env`,
which stage-a writes automatically on the NUC; if the MCP server runs on a different
machine, copy that file across first. `proxmox.env` is gitignored and is the ONLY
place the secret lives — it never goes into the client config below.

## Wire it into Claude

**Claude Desktop** — Settings → Developer → Edit Config (`claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "proxmox-nuc1": {
      "command": "/ABSOLUTE/PATH/home-server/mcp/proxmox/.venv/bin/python",
      "args": ["/ABSOLUTE/PATH/home-server/mcp/proxmox/server.py"]
    }
  }
}
```

Restart Claude Desktop. (No secret here — the server reads `proxmox.env` itself.)

**Claude Code** (terminal):

```bash
claude mcp add proxmox-nuc1 -- /ABSOLUTE/PATH/.venv/bin/python /ABSOLUTE/PATH/server.py
```

## Adding NUC-2 later

Make a second env file and a second client entry pointing at it:

```bash
cp proxmox.env proxmox-nuc2.env   # edit: PROXMOX_HOST=192.168.1.3 + NUC-2's own token
chmod 600 proxmox-nuc2.env
```

```json
"proxmox-nuc2": {
  "command": "/ABSOLUTE/PATH/.venv/bin/python",
  "args": ["/ABSOLUTE/PATH/server.py"],
  "env": { "PROXMOX_ENV": "/ABSOLUTE/PATH/proxmox-nuc2.env" }
}
```

## Security

- The token is scoped (no `Sys.Console`, no `VM.Console`/`VM.Monitor`) — this server
  can build and manage guests but can't open a shell inside one or on the host.
- `PROXMOX_VERIFY_SSL=false` trusts a self-signed cert — fine on a wired LAN, weak over
  anything untrusted. Point it at a CA bundle if you have one.
- `proxmox.env` holds the secret in plaintext: `chmod 600`, never commit it, and if the
  token leaks, `pveum user token remove claude@pve automation` and re-run stage-a.
