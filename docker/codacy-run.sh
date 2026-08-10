#!/usr/bin/env bash
# Runner-side launcher for the Codacy CLIs. Loads the Codacy token from a
# runner-only file into the environment (the CLI reads CODACY_API_TOKEN at
# runtime — no persisted login needed) and execs the real CLI. Invoked as
# `runner` via the sudo shim; the agent (a different uid) cannot read the token
# file (root-owned 640, readable only by the single-member group `runner`) nor
# this process's /proc environ.
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
# Subcommand allowlist — the sudo rule permits any arguments, so the CLI-name check alone still lets
# the agent run `codacy-analysis analyze`, which executes repo tools (e.g. an agent-written
# eslint.config.js) LOCALLY as `runner` with the token loaded — token theft. Permit only the
# subcommands the configure-codacy-cloud skill actually calls.
sub=""
for arg in "$@"; do
  case "${arg}" in
    -*) ;;            # skip flags that precede the subcommand
    *) sub="${arg}"; break;;
  esac
done
case "$name" in
  codacy-analysis) allowed="info init config";;
  codacy)          allowed="repo issues tools tool pattern patterns";;
esac
# Empty means flags only (--help/--version): no subcommand runs, nothing executes, so allow it.
if [ -n "${sub}" ]; then
  case " ${allowed} " in
    *" ${sub} "*) ;;
    *) echo "ERROR: subcommand ${sub} not permitted" >&2; exit 1;;
  esac
fi
# Destructive configuration flags: autoconfig tunes a repository, it never resets one.
for arg in "$@"; do
  case "${arg}" in
    --force|--force=*|--unlink-standard|--unlink-standard=*|--disable-all|--disable-all=*)
      echo "ERROR: flag ${arg} is blocked in the autoconfig container" >&2; exit 1;;
  esac
done
if [ -f /run/codacy/codacy.env ]; then
  set -a; . /run/codacy/codacy.env; set +a
fi
exec "/usr/local/bin/${name}-real" "$@"
