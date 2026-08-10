#!/bin/bash
# Runs as root: performs the privileged setup, then drops to the unprivileged `agent` user with a
# scrubbed environment so a hijacked agent has no credential to read or exfiltrate.
set -e

# The clone init container runs before any agent exists and needs GIT_TOKEN, which the scrub below
# would strip. It exits before the agent container starts, so let it through untouched.
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
printf 'CODACY_API_TOKEN=%s\n' "${CODACY_API_TOKEN}" > /run/codacy/codacy.env
chown -R runner:codacy /run/codacy
chmod 700 /run/codacy
chmod 600 /run/codacy/codacy.env

# The agent and the runner-run CLIs must read and write each other's files under /workspace: both
# share the group `codacy`, setgid makes new files inherit it, umask 002 keeps them group-writable.
# Only in k8s, where /workspace is a pod volume — locally it is the developer's bind-mounted
# repository, whose ownership is not ours to rewrite.
if [[ -n "${RUNNING_IN_K8S:-}" ]]; then
  chown agent:codacy /workspace 2>/dev/null || true
  chmod 2775 /workspace 2>/dev/null || true
fi
umask 002

# Drop to the agent with a clean environment: `env -i` clears everything, only the non-secret vars
# the pipelines actually read are re-added. CODACY_API_TOKEN is deliberately absent — the agent
# reaches it only through the sudo shim, which runs the CLI as runner.
exec runuser -u agent -- env -i \
  PATH="${PATH}" HOME=/home/agent USER=agent TERM="${TERM:-xterm}" \
  RUNNING_IN_K8S="${RUNNING_IN_K8S:-}" \
  RESULT_UPLOAD_URL="${RESULT_UPLOAD_URL:-}" \
  CODACY_PROVIDER="${CODACY_PROVIDER:-}" CODACY_ORG_NAME="${CODACY_ORG_NAME:-}" CODACY_REPO_NAME="${CODACY_REPO_NAME:-}" \
  ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" GEMINI_API_KEY="${GEMINI_API_KEY:-}" \
  CLAUDE_MODEL="${CLAUDE_MODEL:-}" GEMINI_MODEL="${GEMINI_MODEL:-}" \
  WORKSPACE_DIR="${WORKSPACE_DIR:-}" AUTOCONFIG_SUMMARY_PATH="${AUTOCONFIG_SUMMARY_PATH:-}" \
  AUTOCONFIG_AGENT_TIMEOUT="${AUTOCONFIG_AGENT_TIMEOUT:-}" AUTOCONFIG_MAX_SUMMARY_BYTES="${AUTOCONFIG_MAX_SUMMARY_BYTES:-}" \
  "$@"
