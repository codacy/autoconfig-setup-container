#!/bin/bash
# Runs as root. Performs all privileged setup, then drops to the unprivileged
# `agent` user with a scrubbed environment so a hijacked agent has no secret to
# read or exfiltrate.
set -e

PROXY_PORT="${ANTHROPIC_PROXY_PORT:-8118}"

# 1. Egress firewall (skipped in k8s, where NetworkPolicy enforces egress).
if [ -z "${RUNNING_IN_K8S:-}" ]; then
  /usr/local/bin/init-firewall.sh
fi

# 2. Fix ownership of the (root-mounted) tool-cache volume for runner.
chown -R runner:codacy /home/runner/.codacy 2>/dev/null || true

# 3. Pre-authenticate Codacy AS RUNNER, without putting the token in argv
#    (/proc/<pid>/cmdline is world-readable; argv secrets = CWE-214). The token
#    is passed via runner's environment to `codacy login`, never as an argument.
if [ -n "${CODACY_API_TOKEN:-}" ]; then
  runuser -u runner -- env CODACY_API_TOKEN="${CODACY_API_TOKEN}" \
    /usr/local/bin/codacy-real login >/dev/null 2>&1 \
    || echo "entrypoint: codacy login failed (continuing; skill will verify access)" >&2
fi

# 4. Start the Anthropic auth proxy AS RUNNER (the real key lives only here).
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  runuser -u runner -- env ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
    ANTHROPIC_PROXY_PORT="${PROXY_PORT}" \
    node /usr/local/bin/anthropic-proxy.js &
  # Give the proxy a moment to bind before the agent starts.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    runuser -u agent -- bash -c "exec 3<>/dev/tcp/127.0.0.1/${PROXY_PORT}" 2>/dev/null && break
    sleep 0.3
  done
fi

# 5. Drop to the agent with a clean environment: only non-secret vars survive.
#    `env -i` clears everything; we re-add just what the agent needs. The real
#    Anthropic key is NOT here — claude talks to the local proxy with a dummy.
exec runuser -u agent -- env -i \
  PATH=/usr/local/bin:/usr/bin:/bin \
  HOME=/home/agent \
  USER=agent \
  TERM="${TERM:-xterm}" \
  ANTHROPIC_BASE_URL="http://127.0.0.1:${PROXY_PORT}" \
  ANTHROPIC_AUTH_TOKEN="sk-dummy-not-a-real-key" \
  CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 \
  RUNNING_IN_K8S="${RUNNING_IN_K8S:-}" \
  RESULT_UPLOAD_URL="${RESULT_UPLOAD_URL:-}" \
  CODACY_PROVIDER="${CODACY_PROVIDER:-}" \
  CODACY_ORG_NAME="${CODACY_ORG_NAME:-}" \
  CODACY_REPO_NAME="${CODACY_REPO_NAME:-}" \
  "$@"
