#!/usr/bin/env bash
# Installed on PATH as `codacy` and `codacy-analysis`. Hands off to the
# runner-side launcher (codacy-run) via NOPASSWD sudo, which loads the Codacy
# token and execs the real CLI (renamed <name>-real in the same dir so the
# relative npm symlink stays valid). The agent holds no token; -H sets
# HOME=/home/runner.
exec sudo -n -H -u runner /usr/local/bin/codacy-run "$(basename "$0")" "$@"
