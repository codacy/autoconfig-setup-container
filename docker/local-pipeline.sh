#!/bin/bash
# Local pipeline: tunes an already-on-Codacy repository's cloud config from a mounted source folder.
# Runs the /configure-codacy-cloud skill, which uses Codacy Cloud reanalysis (no local analysis tools).
# Requirement: the repo at /workspace must already be on Codacy with at least one finished analysis.
set -e

cd /workspace

# This runs as the unprivileged `agent` (the entrypoint already dropped
# privilege). The real ANTHROPIC_API_KEY is NOT here — claude reaches the
# Anthropic API through the local auth proxy (ANTHROPIC_BASE_URL) with a dummy
# token. The entrypoint enforces that the real key was provided before starting.
echo "==> Running configure-codacy-cloud with Claude..."
claude -p "/configure-codacy-cloud" \
  --permission-mode dontAsk \
  --model haiku \
  --output-format stream-json \
  --verbose \
  --include-partial-messages \
  | jq --unbuffered -rj 'select(.type == "stream_event" and .event.delta.type? == "text_delta") | .event.delta.text'
