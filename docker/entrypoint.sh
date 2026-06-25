#!/bin/bash
set -e

# In k8s, egress is controlled by NetworkPolicy; the in-container iptables firewall
# requires NET_ADMIN and is not available. Skip it when RUNNING_IN_K8S is set.
if [ -z "${RUNNING_IN_K8S:-}" ]; then
  sudo /usr/local/bin/init-firewall.sh
fi

# Fix ownership of the tool-cache volume (mounted as root by Docker)
sudo chown -R node:node /home/node/.codacy 2>/dev/null || true

exec "$@"
