#!/bin/bash
set -e

sudo /usr/local/bin/init-firewall.sh

# Fix ownership of the tool-cache volume (mounted as root by Docker)
sudo chown -R node:node /home/node/.codacy 2>/dev/null || true

# Install Gemini extension from pre-baked local clone (--consent skips the prompt)
if [ -n "${GEMINI_API_KEY:-}" ]; then
  gemini extensions install /opt/codacy-skills --consent 2>/dev/null || true
fi

exec "$@"
