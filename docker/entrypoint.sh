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

# Local flow: /workspace is a host bind mount holding the developer's own files, so the agent adopts
# its uid rather than chowning them. The server flow hands over a root-owned workspace
# (handoff-workspace.sh), which is what the uid 0 case skips.
WORKSPACE="${WORKSPACE_DIR:-/workspace}"
ws_uid=$(stat -c %u "${WORKSPACE}" 2>/dev/null || echo 0)
if [ "${ws_uid}" -ne 0 ] && [ "${ws_uid}" -ne "$(id -u agent)" ]; then
  # Sharing runner's uid would hand the agent the Codacy token the whole split exists to withhold.
  if [ "${ws_uid}" -eq "$(id -u runner)" ]; then
    echo "ERROR: ${WORKSPACE} is owned by uid ${ws_uid}, which the container reserves for the Codacy CLI user" >&2
    exit 1
  fi
  usermod -u "${ws_uid}" agent
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
  ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" GEMINI_API_KEY="${GEMINI_API_KEY:-}" \
  CLAUDE_MODEL="${CLAUDE_MODEL:-}" GEMINI_MODEL="${GEMINI_MODEL:-}" \
  WORKSPACE_DIR="${WORKSPACE_DIR:-}" AUTOCONFIG_SUMMARY_PATH="${AUTOCONFIG_SUMMARY_PATH:-}" \
  AUTOCONFIG_AGENT_TIMEOUT="${AUTOCONFIG_AGENT_TIMEOUT:-}" AUTOCONFIG_MAX_SUMMARY_BYTES="${AUTOCONFIG_MAX_SUMMARY_BYTES:-}" \
  "$@"
