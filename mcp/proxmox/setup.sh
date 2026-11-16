#!/usr/bin/env bash
# setup.sh — stand up the Proxmox MCP server in one go: venv, deps, self-test, and
# print the exact line to register it in your Claude client. Run on the machine that
# runs your Claude client (often NUC-1; could be your laptop). Re-runnable.
set -euo pipefail
cd "$(dirname "$0")"

PY="${PYTHON:-python3}"
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

echo "==> virtualenv (.venv)"
# Debian/Ubuntu ship venv support in a separate package — install it if ensurepip
# is missing, rather than failing halfway (check-and-fix, not a gotcha).
if ! "$PY" -c 'import ensurepip' >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    echo "    installing python3-venv (ensurepip missing)"
    $SUDO apt-get update -qq
    $SUDO apt-get install -y python3-venv \
      || $SUDO apt-get install -y "python$("$PY" -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")')-venv"
  else
    echo "!! python venv support missing and no apt here — install your platform's"
    echo "   python3-venv package, then re-run ./setup.sh"; exit 1
  fi
fi
# (Re)create if absent or broken — a failed venv leaves an unusable .venv behind.
if [ ! -x .venv/bin/python ]; then
  rm -rf .venv
  "$PY" -m venv .venv
fi

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
