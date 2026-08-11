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

# Skips .git so the object store is walked once, by the root:codacy pass below, not twice.
find "${WORKSPACE}" -mindepth 1 -maxdepth 1 ! -name .git -exec chown -R agent:codacy {} + || exit 1

if [[ -e "${WORKSPACE}/.git" ]]; then
  chown -R root:codacy "${WORKSPACE}/.git" || exit 1
  chmod -R g-w "${WORKSPACE}/.git" || exit 1
fi

# The workspace root itself stays root-owned and sticky: without this the agent could not write
# .git, but could rename it aside and drop in a .git of its own, which `safe.directory /workspace`
# would happily accept. Sticky lets the agent create and remove its own entries only; setgid keeps
# everything in the shared group.
chown root:codacy "${WORKSPACE}" || exit 1
chmod 3775 "${WORKSPACE}" || exit 1

exit 0
