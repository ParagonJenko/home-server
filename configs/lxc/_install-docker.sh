#!/usr/bin/env bash
# _install-docker.sh — install Docker + compose plugin inside a container.
# Run with `pct enter <ctid>` first, or `pct exec <ctid> -- bash _install-docker.sh`.
set -euo pipefail

curl -fsSL https://get.docker.com | sh
systemctl enable --now docker
docker version
# Containers need `--features nesting=1,keyctl=1` at create time (see the C2/C3 pattern):
# nesting alone starts dockerd, but without keyctl it fails on startup with permission errors.
