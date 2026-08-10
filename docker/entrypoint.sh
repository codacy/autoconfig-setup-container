#!/bin/bash
# Runs as root: performs the privileged setup, then drops to the unprivileged `agent` user with a
# scrubbed environment so a hijacked agent has no credential to read or exfiltrate.
set -e

# The clone init container runs before any agent exists and needs GIT_TOKEN, which the scrub below
# would strip. It exits before the agent container starts, so let it through untouched.
# Production bypasses this entrypoint entirely (the AAM pod spec overrides the init container's
# command); this keeps a plain `docker run <image> clone-workspace.sh` working the same way.
case "${1:-}" in
  clone-workspace.sh | /usr/local/bin/clone-workspace.sh) exec "$@" ;;
esac

# Fix ownership of the tool-cache volume (mounted as root by Docker); the CLIs run as runner.
chown -R runner:codacy /home/runner/.codacy 2>/dev/null || true

# The Codacy CLI reads CODACY_API_TOKEN from its environment at runtime, so stage it in a
# runner-only file instead of argv — a command line is world-readable (CWE-214).
if [ -z "${CODACY_API_TOKEN:-}" ]; then
  echo "ERROR: missing required env vars: CODACY_API_TOKEN" >&2
  exit 1
fi
# The pipelines check this too, but the agent never sees ANTHROPIC_API_KEY — fail here, where the
# real key is still visible, rather than after the privilege drop.
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${GEMINI_API_KEY:-}" ]; then
  echo "ERROR: missing required env vars: ANTHROPIC_API_KEY or GEMINI_API_KEY (at least one must be set)" >&2
  exit 1
fi
mkdir -p /run/codacy
chown root:runner /run/codacy
chmod 750 /run/codacy
# 077 closes the window between creation and chmod, in which the file would otherwise be 644.
umask 077
# %q quotes the value, so a token containing shell metacharacters cannot turn into a command when
# codacy-run sources this file.
printf 'export CODACY_API_TOKEN=%q\n' "${CODACY_API_TOKEN}" > /run/codacy/codacy.env
# Only the Codacy CLI reads the API host, and it runs as runner — so it travels with the token
# rather than through the agent's environment.
if [ -n "${CODACY_API_BASE_URL:-}" ]; then
  printf 'export CODACY_API_BASE_URL=%q\n' "${CODACY_API_BASE_URL}" >> /run/codacy/codacy.env
fi
# root owns it, runner only reads it: a compromised runner cannot rewrite or widen the file.
chown root:runner /run/codacy/codacy.env
chmod 640 /run/codacy/codacy.env

# Anthropic auth proxy: it runs as runner and holds the real key in its own environment, so the
# agent talks to 127.0.0.1 with a dummy credential and never has a key it could exfiltrate.
ANTHROPIC_ENV=()
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  PROXY_PORT="${ANTHROPIC_PROXY_PORT:-8118}"
  # env -i keeps CODACY_API_TOKEN out of the proxy's /proc/<pid>/environ as well.
  runuser -u runner -- env -i PATH="${PATH}" \
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" ANTHROPIC_PROXY_PORT="${PROXY_PORT}" \
    node /usr/local/bin/anthropic-proxy.js &
  proxy_up=0
  for _ in $(seq 30); do
    if (exec 3<>"/dev/tcp/127.0.0.1/${PROXY_PORT}") 2>/dev/null; then proxy_up=1; break; fi
    sleep 0.1
  done
  if [ "${proxy_up}" -ne 1 ]; then
    echo "ERROR: anthropic proxy did not bind 127.0.0.1:${PROXY_PORT}" >&2
    exit 1
  fi
  ANTHROPIC_ENV=(ANTHROPIC_BASE_URL="http://127.0.0.1:${PROXY_PORT}" ANTHROPIC_AUTH_TOKEN="sk-dummy-not-a-real-key")
fi

# Both users share the group `codacy`, so a group-writable file is readable and writable by the
# agent and by the runner-run CLIs alike.
umask 002

# Drop to the agent with a clean environment: `env -i` clears everything, only the non-secret vars
# the pipelines actually read are re-added. CODACY_API_TOKEN is deliberately absent — the agent
# reaches it only through the sudo shim, which runs the CLI as runner.
exec runuser -u agent -- env -i \
  PATH="${PATH}" HOME=/home/agent USER=agent TERM="${TERM:-xterm}" \
  RESULT_UPLOAD_URL="${RESULT_UPLOAD_URL:-}" \
  CODACY_PROVIDER="${CODACY_PROVIDER:-}" CODACY_ORG_NAME="${CODACY_ORG_NAME:-}" CODACY_REPO_NAME="${CODACY_REPO_NAME:-}" \
  "${ANTHROPIC_ENV[@]}" GEMINI_API_KEY="${GEMINI_API_KEY:-}" \
  CLAUDE_MODEL="${CLAUDE_MODEL:-}" GEMINI_MODEL="${GEMINI_MODEL:-}" \
  WORKSPACE_DIR="${WORKSPACE_DIR:-}" AUTOCONFIG_SUMMARY_PATH="${AUTOCONFIG_SUMMARY_PATH:-}" \
  AUTOCONFIG_AGENT_TIMEOUT="${AUTOCONFIG_AGENT_TIMEOUT:-}" AUTOCONFIG_MAX_SUMMARY_BYTES="${AUTOCONFIG_MAX_SUMMARY_BYTES:-}" \
  "$@"
