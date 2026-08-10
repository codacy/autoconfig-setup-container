#!/bin/bash
# Hands a freshly cloned workspace over to the agent container, which runs as `agent`.
#
# The agent owns the checkout but NOT .git: git config carries executable settings (core.fsmonitor,
# core.pager, hooks) that the Codacy CLIs would run as `runner` — the user that holds the token —
# the next time they touch the repository. The agent keeps read access through the shared group.

set -uo pipefail

WORKSPACE="${1:?usage: handoff-workspace.sh <workspace-dir>}"

if [[ ! -d "${WORKSPACE}" ]]; then
  echo "ERROR: handoff-workspace: '${WORKSPACE}' is not a directory" >&2
  exit 1
fi

chown -R agent:codacy "${WORKSPACE}" || exit 1

if [[ -e "${WORKSPACE}/.git" ]]; then
  chown -R root:codacy "${WORKSPACE}/.git" || exit 1
  chmod -R g-w "${WORKSPACE}/.git" || exit 1
fi

exit 0
