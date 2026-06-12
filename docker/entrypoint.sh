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

# 3. Stage the Codacy token for the runner-side CLI launcher. The Codacy CLI
#    reads CODACY_API_TOKEN from its environment at runtime, so no persisted
#    login is needed. We write it to a runner-only file (600) OUTSIDE the
#    persisted tool-cache volume, never to argv (cmdline is world-readable;
#    argv secrets = CWE-214). The agent (uid 1002) cannot read it.
if [ -n "${CODACY_API_TOKEN:-}" ]; then
  mkdir -p /run/codacy
  printf 'CODACY_API_TOKEN=%s\n' "${CODACY_API_TOKEN}" > /run/codacy/codacy.env
  chown -R runner:codacy /run/codacy
  chmod 700 /run/codacy
  chmod 600 /run/codacy/codacy.env
fi

# 4. Start the Anthropic auth proxy AS RUNNER (the real key lives only here).
#    ANTHROPIC_API_KEY is required: the agent reaches Anthropic only through this
#    proxy, and Gemini is not supported.
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "ERROR: ANTHROPIC_API_KEY is not set." >&2
  exit 1
fi
runuser -u runner -- env ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
  ANTHROPIC_PROXY_PORT="${PROXY_PORT}" \
  node /usr/local/bin/anthropic-proxy.js &
# Give the proxy a moment to bind before the agent starts.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  runuser -u agent -- bash -c "exec 3<>/dev/tcp/127.0.0.1/${PROXY_PORT}" 2>/dev/null && break
  sleep 0.3
done

# 4b. Shared scratch for the dual config mechanism: runner-run CLIs write here
#     and the agent edits the files. setgid + group `codacy` + umask 002 keep
#     both able to read/write each other's files.
mkdir -p /workspace/.codacy
chown runner:codacy /workspace/.codacy 2>/dev/null || true
chmod 2775 /workspace/.codacy 2>/dev/null || true
umask 002

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
