#!/usr/bin/env bash
# Installed on PATH as `codacy` and `codacy-analysis`. Runs the real CLI
# (renamed to <name>-real in the same dir, so the relative npm symlink stays
# valid) as the `runner` user via NOPASSWD sudo, so the credentials file stays
# unreadable by the agent. -H sets HOME=/home/runner so the CLI finds its
# credentials at /home/runner/.codacy/credentials.
exec sudo -n -H -u runner "/usr/local/bin/$(basename "$0")-real" "$@"
