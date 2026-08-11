#!/usr/bin/env bash
# Redacts secret-shaped tokens from a summary JSON in place, before it is
# uploaded. Defense-in-depth: even though the agent should hold no secret, the
# summary is agent-authored free text and must never carry a credential.
set -euo pipefail
FILE="$1"
[ -f "$FILE" ] || exit 0

# Anthropic keys (sk-ant-...), bearer-style sk- tokens, and GitHub PAT prefixes.
# No generic long-hex rule on purpose: a summary legitimately carries commit SHAs and content
# hashes, and redacting those corrupts the report. Credentials we stage all have a named prefix.
sed -E -i \
  -e 's/sk-ant-[A-Za-z0-9_-]{8,}/REDACTED/g' \
  -e 's/sk-[A-Za-z0-9_-]{16,}/REDACTED/g' \
  -e 's/(ghp|gho|ghs|github_pat)_[A-Za-z0-9_]{16,}/REDACTED/g' \
  "$FILE"
