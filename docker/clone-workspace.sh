#!/bin/bash
# Init container: clones + sanitizes the repo into the shared /workspace, then exits.
# Runs to completion before the agent container, so GIT_TOKEN never reaches the agent.
# Non-zero exit keeps the agent container from starting.

set -uo pipefail

# The agent container runs as `agent` and the Codacy CLIs as `runner`; both must be able to edit
# what this container clones.
umask 002

# shellcheck source=docker/agent-lib.sh
source /usr/local/bin/agent-lib.sh

WORKSPACE="${WORKSPACE_DIR:-/workspace}"

# The k8s init container overrides the image ENTRYPOINT, so entrypoint.sh never runs and this script
# would clone and sanitize an attacker-controlled repository as uid 0. Do the privileged part here
# and re-exec the rest as the agent; only the handoff, which must chown, stays root.
if [[ $(id -u) -eq 0 ]]; then
  mkdir -p "${WORKSPACE}" || exit ${EXIT_BAD_INPUT}
  chown agent:codacy "${WORKSPACE}" || exit ${EXIT_BAD_INPUT}
  chmod 2775 "${WORKSPACE}" || exit ${EXIT_BAD_INPUT}
  runuser -u agent -- /usr/local/bin/clone-workspace.sh "$@" || exit $?

  if ! /usr/local/bin/handoff-workspace.sh "${WORKSPACE}"; then
    echo "ERROR: failed to hand the workspace over to the agent user; refusing to launch the agent" >&2
    exit ${EXIT_BAD_INPUT}
  fi

  echo "==> Workspace ready at ${WORKSPACE}"
  exit ${EXIT_OK}
fi

REQUIRED_VARS=(
  GIT_TOKEN
  CODACY_PROVIDER
  CODACY_ORG_NAME
  CODACY_REPO_NAME
)

missing=()
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    missing+=("$var")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: missing required env vars: ${missing[*]}" >&2
  exit ${EXIT_BAD_INPUT}
fi

# Provider-specific HTTPS clone URL construction.
# Token value comes from GIT_TOKEN; the username portion differs per provider.
case "${CODACY_PROVIDER}" in
  gh|ghe)
    GIT_USERNAME="x-access-token"
    GIT_HOST_DEFAULT="github.com"
    ;;
  gl|gle)
    GIT_USERNAME="oauth2"
    GIT_HOST_DEFAULT="gitlab.com"
    ;;
  bb)
    GIT_USERNAME="x-token-auth"
    GIT_HOST_DEFAULT="bitbucket.org"
    ;;
  *)
    echo "ERROR: unsupported CODACY_PROVIDER '${CODACY_PROVIDER}' (expected gh, ghe, gl, gle, bb)" >&2
    exit ${EXIT_BAD_INPUT}
    ;;
esac

CLONE_HOST="${CODACY_REPO_CLONE_HOST:-${GIT_HOST_DEFAULT}}"
CLONE_URL="https://${GIT_USERNAME}:${GIT_TOKEN}@${CLONE_HOST}/${CODACY_ORG_NAME}/${CODACY_REPO_NAME}.git"

echo "==> Cloning ${CODACY_PROVIDER}/${CODACY_ORG_NAME}/${CODACY_REPO_NAME} into ${WORKSPACE}"
if ! git clone --depth 1 "${CLONE_URL}" "${WORKSPACE}" 2>&1 | sed "s|${GIT_USERNAME}:[^@]*@|${GIT_USERNAME}:***@|g"; then
  echo "ERROR: git clone failed" >&2
  exit ${EXIT_BAD_INPUT}
fi

if ! /usr/local/bin/sanitize-workspace.sh "${WORKSPACE}"; then
  echo "ERROR: failed to sanitize the cloned workspace; refusing to launch the agent" >&2
  exit ${EXIT_BAD_INPUT}
fi

exit ${EXIT_OK}
