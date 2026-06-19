#!/bin/bash
# Local pipeline: tunes an already-on-Codacy repository's cloud config from a mounted source folder.
# Runs the /configure-codacy-cloud skill, which uses Codacy Cloud reanalysis (no local analysis tools).
# Requirement: the repo at /workspace must already be on Codacy with at least one finished analysis.
set -uo pipefail

WORKSPACE="${WORKSPACE_DIR:-/workspace}"
SUMMARY_PATH="${AUTOCONFIG_SUMMARY_PATH:-${WORKSPACE}/.codacy/configure-codacy-cloud-summary.json}"

cd "${WORKSPACE}"
mkdir -p "$(dirname "${SUMMARY_PATH}")"

if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  CLAUDE_STREAM_FILE=$(mktemp)

  echo "==> Running configure-codacy-cloud with Claude..."
  claude -p "/configure-codacy-cloud" \
    --output-format stream-json \
    --verbose \
    --include-partial-messages \
    | tee "${CLAUDE_STREAM_FILE}" \
    | jq --unbuffered -rj 'select(.type == "stream_event" and .event.delta.type? == "text_delta") | .event.delta.text'
  SKILL_EXIT=${PIPESTATUS[0]}
  echo

  # Extract run metadata from the captured stream.
  # model lives on assistant message events (.message.model), not on the result event.
  RUN_META=$(jq -rsc '
    . as $events |
    ($events | map(select(.type == "assistant")) | first | .message.model // "unknown") as $model |
    ($events | map(select(.type == "result")) | last) as $result |
    $result | {
      llm: "anthropic",
      model: $model,
      tokensIn: (.usage.input_tokens // 0),
      tokensOut: (.usage.output_tokens // 0),
      durationMs: (.duration_ms // 0),
      costUsd: (.total_cost_usd // 0),
      sessionId: (.session_id // "")
    }
  ' "${CLAUDE_STREAM_FILE}")
  rm -f "${CLAUDE_STREAM_FILE}"

elif [ -n "${GEMINI_API_KEY:-}" ]; then
  echo "==> Running configure-codacy-cloud with Gemini..."
  echo "/configure-codacy-cloud" | gemini
  SKILL_EXIT=$?
  RUN_META=""

else
  echo "Error: neither ANTHROPIC_API_KEY nor GEMINI_API_KEY is set." >&2
  exit 1
fi

if [[ ! -f "${SUMMARY_PATH}" ]]; then
  echo "==> Skill did not produce ${SUMMARY_PATH}, writing fallback summary"
  if [[ ${SKILL_EXIT} -eq 0 ]]; then
    printf '%s\n' '{"status":"completed","note":"skill exited 0 but did not write a summary"}' > "${SUMMARY_PATH}"
  else
    printf '{"status":"failed","exitCode":%d,"reason":"skill exited non-zero without writing a summary"}\n' "${SKILL_EXIT}" > "${SUMMARY_PATH}"
  fi
fi

if [[ -n "${RUN_META}" ]]; then
  jq --argjson run "${RUN_META}" '. + {run: $run}' \
    "${SUMMARY_PATH}" > "${SUMMARY_PATH}.tmp" && mv "${SUMMARY_PATH}.tmp" "${SUMMARY_PATH}"
fi

if [[ ${SKILL_EXIT} -ne 0 ]]; then
  echo "ERROR: configure-codacy-cloud exited with code ${SKILL_EXIT}" >&2
  exit ${SKILL_EXIT}
fi

echo "==> Autoconfig completed successfully"
