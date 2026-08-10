#!/bin/bash
# Local pipeline: tunes an already-on-Codacy repository's cloud config from a mounted source folder.
# Runs the /configure-codacy-cloud skill, which uses Codacy Cloud reanalysis (no local analysis tools).
# Requirement: the repo at /workspace must already be on Codacy with at least one finished analysis.
set -uo pipefail

# shellcheck source=docker/agent-lib.sh
source /usr/local/bin/agent-lib.sh

WORKSPACE="${WORKSPACE_DIR:-/workspace}"
SUMMARY_PATH="${AUTOCONFIG_SUMMARY_PATH:-${WORKSPACE}/.codacy/configure-codacy-cloud-summary.json}"
AGENT_TIMEOUT="${AUTOCONFIG_AGENT_TIMEOUT:-70m}"

cd "${WORKSPACE}"
mkdir -p "$(dirname "${SUMMARY_PATH}")"

AGENT_ERROR=""

# The real Anthropic key stays with the proxy (runner); ANTHROPIC_BASE_URL is what says Claude is wired up.
if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
  CLAUDE_STREAM_FILE=$(mktemp)
  RUN_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  echo "==> Running configure-codacy-cloud with Claude (timeout ${AGENT_TIMEOUT})..."
  timeout --signal=TERM --kill-after=1m "${AGENT_TIMEOUT}" \
  claude -p "/configure-codacy-cloud" \
    --model "${CLAUDE_MODEL:-claude-sonnet-4-6}" \
    --append-system-prompt "${SECRECY_RULES}" \
    --setting-sources user \
    --strict-mcp-config \
    --output-format stream-json \
    --verbose \
    --include-partial-messages \
    | tee "${CLAUDE_STREAM_FILE}" \
    | jq --unbuffered -rj 'select(.type == "stream_event" and .event.delta.type? == "text_delta") | .event.delta.text'
  SKILL_EXIT=${PIPESTATUS[0]}
  RUN_FINISHED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo

  AGENT_ERROR=$(agent_error_from_stream "${CLAUDE_STREAM_FILE}")

  # Extract run metadata from the captured stream.
  # model lives on assistant message events (.message.model), not on the result event.
  RUN_META=$(jq -rsc \
    --arg startedAt "${RUN_STARTED_AT}" \
    --arg finishedAt "${RUN_FINISHED_AT}" '
    . as $events |
    ($events | map(select(.type == "assistant")) | first | .message.model // "unknown") as $model |
    ($events | map(select(.type == "result")) | last) as $result |
    $result | {
      llm: "anthropic",
      model: $model,
      startedAt: $startedAt,
      finishedAt: $finishedAt,
      tokensIn: (.usage.input_tokens // 0),
      tokensOut: (.usage.output_tokens // 0),
      durationMs: (.duration_ms // 0),
      costUsd: (.total_cost_usd // 0),
      sessionId: (.session_id // "")
    }
  ' "${CLAUDE_STREAM_FILE}")
  rm -f "${CLAUDE_STREAM_FILE}"

elif [ -n "${GEMINI_API_KEY:-}" ]; then
  echo "==> Running configure-codacy-cloud with Gemini (timeout ${AGENT_TIMEOUT})..."
  SKILL_MD="/opt/codacy-skills/skills/configure-codacy-cloud/SKILL.md"
  if [[ ! -f "${SKILL_MD}" ]]; then
    echo "ERROR: ${SKILL_MD} not found in the container" >&2
    exit ${EXIT_BAD_INPUT}
  fi
  GEMINI_STREAM_FILE=$(mktemp)
  RUN_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  timeout --signal=TERM --kill-after=1m "${AGENT_TIMEOUT}" \
  gemini -y --skip-trust -m "${GEMINI_MODEL:-gemini-3-flash-preview}" -o stream-json \
    -p "Execute the skill instructions provided above."$'\n\n'"${SECRECY_RULES}" < "${SKILL_MD}" \
    | tee "${GEMINI_STREAM_FILE}" \
    | jq --unbuffered -rj 'select(.type == "message" and .role == "assistant") | .content'
  SKILL_EXIT=${PIPESTATUS[0]}
  RUN_FINISHED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo

  AGENT_ERROR=$(agent_error_from_stream "${GEMINI_STREAM_FILE}")

  RUN_META=$(jq -rsc \
    --arg startedAt "${RUN_STARTED_AT}" \
    --arg finishedAt "${RUN_FINISHED_AT}" '
    . as $events |
    ($events | map(select(.type == "init")) | first | .session_id // "") as $sessionId |
    ($events | map(select(.type == "init")) | first | .model // "unknown") as $model |
    ($events | map(select(.type == "result")) | last) as $result |
    {
      llm: "gemini",
      model: $model,
      startedAt: $startedAt,
      finishedAt: $finishedAt,
      tokensIn: ($result.stats.input_tokens // 0),
      tokensOut: ($result.stats.output_tokens // 0),
      durationMs: ($result.stats.duration_ms // 0),
      costUsd: ((($result.stats.input_tokens // 0) * 0.50 + ($result.stats.output_tokens // 0) * 3.00) / 1000000),
      sessionId: $sessionId
    }
  ' "${GEMINI_STREAM_FILE}")
  rm -f "${GEMINI_STREAM_FILE}"

else
  echo "Error: neither ANTHROPIC_API_KEY nor GEMINI_API_KEY is set." >&2
  exit ${EXIT_BAD_INPUT}
fi

SUMMARY_PROBLEM=$(discard_unusable_summary "${SUMMARY_PATH}" "${AUTOCONFIG_MAX_SUMMARY_BYTES:-1048576}")

derive_outcome "${SKILL_EXIT}" "${AGENT_ERROR}" "${SUMMARY_PATH}" "${AGENT_TIMEOUT}" "${SUMMARY_PROBLEM}"

if [[ -f "${SUMMARY_PATH}" && -n "${RUN_META}" ]]; then
  jq --argjson run "${RUN_META}" '. + {run: $run}' \
    "${SUMMARY_PATH}" > "${SUMMARY_PATH}.tmp" && mv "${SUMMARY_PATH}.tmp" "${SUMMARY_PATH}"
fi

if [[ ${OUTCOME_EXIT} -ne ${EXIT_OK} ]]; then
  echo "ERROR: autoconfig did not complete (exit ${OUTCOME_EXIT}): ${OUTCOME_REASON}" >&2
  exit ${OUTCOME_EXIT}
fi

echo "==> Autoconfig completed successfully"
