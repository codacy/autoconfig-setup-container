#!/usr/bin/env bash
# Redacts secret-shaped tokens from a summary JSON in place, before it is
# uploaded. Defense-in-depth: even though the agent should hold no secret, the
# summary is agent-authored free text and must never carry a credential.
set -euo pipefail
FILE="$1"
[ -f "$FILE" ] || exit 0

# Anthropic keys (sk-ant-...), generic long hex/base64 tokens (>=32 chars),
# bearer-style sk- tokens, and GitHub PAT prefixes.
sed -E -i \
  -e 's/sk-ant-[A-Za-z0-9_-]{8,}/REDACTED/g' \
  -e 's/sk-[A-Za-z0-9_-]{16,}/REDACTED/g' \
  -e 's/[A-Fa-f0-9]{32,}/REDACTED/g' \
  -e 's/(ghp|gho|ghs|github_pat)_[A-Za-z0-9_]{16,}/REDACTED/g' \
  "$FILE"
