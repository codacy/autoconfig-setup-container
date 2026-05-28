#!/bin/bash
set -e

cd /workspace

if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  echo "==> Running configure-codacy with Claude..."
  claude -p "/configure-codacy import" \
    --output-format stream-json \
    --verbose \
    --include-partial-messages \
    | jq --unbuffered -rj 'select(.type == "stream_event" and .event.delta.type? == "text_delta") | .event.delta.text'

elif [ -n "${GEMINI_API_KEY:-}" ]; then
  echo "==> Running configure-codacy with Gemini..."
  echo "/configure-codacy import" | gemini

else
  echo "Error: neither ANTHROPIC_API_KEY nor GEMINI_API_KEY is set." >&2
  exit 1
fi
