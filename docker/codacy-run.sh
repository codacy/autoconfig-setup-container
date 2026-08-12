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
case "$name" in
  codacy-analysis) allowed="info init config";;
  codacy)          allowed="repo issues tools tool pattern patterns";;
esac
# Both CLIs are commander-based and subcommand-first (`codacy <sub> …`), so the subcommand must be
# $1. Scanning past leading flags instead let a value-taking global flag occupy that position and
# smuggle a denied subcommand through: `codacy-analysis --directory info analyze` reads as `info`.
sub="${1:-}"
case "${sub}" in
  # These print and exit without running any subcommand.
  --help|-h|--version|-V) ;;
  ""|-*) echo "ERROR: expected a subcommand as the first argument, got '${sub}'" >&2; exit 1;;
  *)
    case " ${allowed} " in
      *" ${sub} "*) ;;
      *) echo "ERROR: subcommand ${sub} not permitted" >&2; exit 1;;
    esac;;
esac
# Destructive configuration flags: autoconfig tunes a repository, it never resets one.
# -K (--unlink-standard) and -X (--disable-all) are real short aliases, and commander bundles short
# flags, so any single-dash cluster containing K or X is rejected too. --force has no short alias.
for arg in "$@"; do
  case "${arg}" in
    --force|--force=*|--unlink-standard|--unlink-standard=*|--disable-all|--disable-all=*|-[KX]*|-[!-]*[KX]*)
      echo "ERROR: flag ${arg} is blocked in the autoconfig container" >&2; exit 1;;
  esac
done
if [ -f /run/codacy/codacy.env ]; then
  set -a; . /run/codacy/codacy.env; set +a
fi
# sudo forces umask 0022 regardless of the caller's, so the config the CLI generates would land 644
# and the agent — a different uid, sharing only the group — could not edit it.
umask 002
exec "/usr/local/bin/${name}-real" "$@"
