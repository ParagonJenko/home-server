#!/usr/bin/env bash
# setup.sh — stand up the Proxmox MCP server in one go: venv, deps, self-test, and
# print the exact line to register it in your Claude client. Run on the machine that
# runs your Claude client (often NUC-1; could be your laptop). Re-runnable.
set -euo pipefail
cd "$(dirname "$0")"

PY="${PYTHON:-python3}"

echo "==> virtualenv (.venv)"
[ -d .venv ] || "$PY" -m venv .venv

echo "==> dependencies"
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -r requirements.txt

if [ ! -f proxmox.env ]; then
  echo
  echo "!! proxmox.env is missing."
  echo "   stage-a writes it automatically on the NUC. If the MCP server runs on a"
  echo "   different machine, copy proxmox.env across from the NUC — or, to start fresh:"
  echo "       cp proxmox.env.example proxmox.env   # then fill PROXMOX_TOKEN_SECRET"
  echo "   Then re-run ./setup.sh"
  exit 1
fi
chmod 600 proxmox.env

echo "==> self-test (lists Proxmox nodes)"
.venv/bin/python server.py --selftest

DIR="$(pwd)"
echo
echo "MCP server ready. Register it in your Claude client (this is the one manual bit):"
echo
echo "  Claude Desktop — Settings -> Developer -> Edit Config, add under mcpServers:"
echo "    \"proxmox-nuc1\": { \"command\": \"${DIR}/.venv/bin/python\", \"args\": [\"${DIR}/server.py\"] }"
echo
echo "  Claude Code — run:"
echo "    claude mcp add proxmox-nuc1 -- ${DIR}/.venv/bin/python ${DIR}/server.py"
