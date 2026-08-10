#!/bin/bash
set -e

# Fix ownership of the tool-cache volume (mounted as root by Docker)
sudo chown -R node:node /home/node/.codacy 2>/dev/null || true

exec "$@"
