#!/usr/bin/env bash
# Runner-side launcher for the Codacy CLIs. Loads the Codacy token from a
# runner-only file into the environment (the CLI reads CODACY_API_TOKEN at
# runtime — no persisted login needed) and execs the real CLI. Invoked as
# `runner` via the sudo shim; the agent (a different uid) cannot read the token
# file (600, runner-owned) nor this process's /proc environ.
set -euo pipefail
name="$1"; shift
# Allowlist the CLI name — the agent reaches this via a sudo rule that permits
# any arguments, so without this an attacker could pass a traversal path
# (e.g. ../../workspace/evil) to run an arbitrary binary as `runner` with the
# token loaded. Only the two real Codacy CLIs are permitted.
case "$name" in
  codacy|codacy-analysis) ;;
  *) echo "codacy-run: unauthorized CLI name '$name'" >&2; exit 1 ;;
esac
if [ -f /run/codacy/codacy.env ]; then
  set -a; . /run/codacy/codacy.env; set +a
fi
exec "/usr/local/bin/${name}-real" "$@"
