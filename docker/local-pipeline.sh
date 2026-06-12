#!/bin/bash
# Local pipeline: tunes an already-on-Codacy repository's cloud config from a mounted source folder.
# Runs the /configure-codacy-cloud skill, which uses Codacy Cloud reanalysis (no local analysis tools).
# Requirement: the repo at /workspace must already be on Codacy with at least one finished analysis.
set -e

cd /workspace

if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  echo "==> Running configure-codacy-cloud with Claude..."
  claude -p "/configure-codacy-cloud" \
    --permission-mode dontAsk \
    --model haiku \
    --output-format stream-json \
    --verbose \
    --include-partial-messages \
    | jq --unbuffered -rj 'select(.type == "stream_event" and .event.delta.type? == "text_delta") | .event.delta.text'

elif [ -n "${GEMINI_API_KEY:-}" ]; then
  echo "==> Running configure-codacy-cloud with Gemini..."
  echo "/configure-codacy-cloud" | gemini

else
  echo "Error: neither ANTHROPIC_API_KEY nor GEMINI_API_KEY is set." >&2
  exit 1
fi
