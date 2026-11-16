#!/usr/bin/env bash
# _install-docker.sh — install Docker + compose plugin inside a container.
# Run with `pct enter <ctid>` first, or `pct exec <ctid> -- bash _install-docker.sh`.
set -euo pipefail

# The Debian LXC template is minimal — no curl or ca-certificates — and
# get.docker.com needs both. Install them first.
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates

curl -fsSL https://get.docker.com | sh
systemctl enable --now docker
docker version
# Containers need `--features nesting=1,keyctl=1` at create time (see the C2 pattern):
# nesting alone starts dockerd, but without keyctl it fails on startup with permission errors.
