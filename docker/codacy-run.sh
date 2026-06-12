#!/usr/bin/env bash
# Runner-side launcher for the Codacy CLIs. Loads the Codacy token from a
# runner-only file into the environment (the CLI reads CODACY_API_TOKEN at
# runtime — no persisted login needed) and execs the real CLI. Invoked as
# `runner` via the sudo shim; the agent (a different uid) cannot read the token
# file (600, runner-owned) nor this process's /proc environ.
set -euo pipefail
name="$1"; shift
if [ -f /run/codacy/codacy.env ]; then
  set -a; . /run/codacy/codacy.env; set +a
fi
exec "/usr/local/bin/${name}-real" "$@"
