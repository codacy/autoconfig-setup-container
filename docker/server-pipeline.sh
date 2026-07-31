#!/bin/bash
# Server-side autoconfig entrypoint. Runs in the AAM-launched k8s pod.
# Validates env vars, clones the repo, runs the configure-codacy-cloud skill,
# uploads the summary JSON to a presigned S3 URL, and exits with the correct status.
#
# Exit status is the only signal AAM has: a zero exit is booked as a successful run and spends the
# organization's daily autoconfig quota. Anything short of a verified configuration run must
# therefore exit non-zero.

set -uo pipefail

# shellcheck source=docker/agent-lib.sh
source /usr/local/bin/agent-lib.sh

REQUIRED_VARS=(
  CODACY_API_TOKEN
  GIT_TOKEN
  CODACY_PROVIDER
  CODACY_ORG_NAME
  CODACY_REPO_NAME
  RESULT_UPLOAD_URL
)

missing=()
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    missing+=("$var")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: missing required env vars: ${missing[*]}" >&2
  exit ${EXIT_BAD_INPUT}
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${GEMINI_API_KEY:-}" ]]; then
  echo "ERROR: missing required env vars: ANTHROPIC_API_KEY or GEMINI_API_KEY (at least one must be set)" >&2
  exit ${EXIT_BAD_INPUT}
fi

# Provider-specific HTTPS clone URL construction.
# Token value comes from GIT_TOKEN; the username portion differs per provider.
case "${CODACY_PROVIDER}" in
  gh|ghe)
    GIT_USERNAME="x-access-token"
    GIT_HOST_DEFAULT="github.com"
    ;;
  gl|gle)
    GIT_USERNAME="oauth2"
    GIT_HOST_DEFAULT="gitlab.com"
    ;;
  bb)
    GIT_USERNAME="x-token-auth"
    GIT_HOST_DEFAULT="bitbucket.org"
    ;;
  *)
    echo "ERROR: unsupported CODACY_PROVIDER '${CODACY_PROVIDER}' (expected gh, ghe, gl, gle, bb)" >&2
    exit ${EXIT_BAD_INPUT}
    ;;
esac

WORKSPACE="${WORKSPACE_DIR:-/workspace}"
SUMMARY_PATH="${AUTOCONFIG_SUMMARY_PATH:-${WORKSPACE}/.codacy/configure-codacy-cloud-summary.json}"
CLONE_HOST="${CODACY_REPO_CLONE_HOST:-${GIT_HOST_DEFAULT}}"
CLONE_URL="https://${GIT_USERNAME}:${GIT_TOKEN}@${CLONE_HOST}/${CODACY_ORG_NAME}/${CODACY_REPO_NAME}.git"

# Nothing inside the pod bounds an agent that stalls, so cap it here.
AGENT_TIMEOUT="${AUTOCONFIG_AGENT_TIMEOUT:-70m}"

echo "==> Cloning ${CODACY_PROVIDER}/${CODACY_ORG_NAME}/${CODACY_REPO_NAME} into ${WORKSPACE}"
if ! git clone --depth 1 "${CLONE_URL}" "${WORKSPACE}" 2>&1 | sed "s|${GIT_USERNAME}:[^@]*@|${GIT_USERNAME}:***@|g"; then
  echo "ERROR: git clone failed" >&2
  exit ${EXIT_BAD_INPUT}
fi

if ! /usr/local/bin/sanitize-workspace.sh "${WORKSPACE}"; then
  echo "ERROR: failed to sanitize the cloned workspace; refusing to launch the agent" >&2
  exit ${EXIT_BAD_INPUT}
fi

cd "${WORKSPACE}"
mkdir -p "$(dirname "${SUMMARY_PATH}")"

AGENT_ENV=(env -u GIT_TOKEN -u RESULT_UPLOAD_URL)
AGENT_ERROR=""

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  CLAUDE_STREAM_FILE=$(mktemp)
  RUN_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  echo "==> Running configure-codacy-cloud with Claude (timeout ${AGENT_TIMEOUT})..."
  "${AGENT_ENV[@]}" \
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

elif [[ -n "${GEMINI_API_KEY:-}" ]]; then
  echo "==> Running configure-codacy-cloud with Gemini (timeout ${AGENT_TIMEOUT})..."
  SKILL_MD="/opt/codacy-skills/skills/configure-codacy-cloud/SKILL.md"
  if [[ ! -f "${SKILL_MD}" ]]; then
    echo "ERROR: ${SKILL_MD} not found in the container" >&2
    exit ${EXIT_BAD_INPUT}
  fi
  GEMINI_STREAM_FILE=$(mktemp)
  RUN_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  "${AGENT_ENV[@]}" \
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
fi

SUMMARY_PROBLEM=$(discard_unusable_summary "${SUMMARY_PATH}" "${AUTOCONFIG_MAX_SUMMARY_BYTES:-1048576}")

derive_outcome "${SKILL_EXIT}" "${AGENT_ERROR}" "${SUMMARY_PATH}" "${AGENT_TIMEOUT}" "${SUMMARY_PROBLEM}"

# Record the outcome in the summary too. AAM decides from the exit code, not from this — it is here so
# the reason survives in the stored report for whoever reads it later.
[[ -f "${SUMMARY_PATH}" ]] || printf '%s\n' '{}' > "${SUMMARY_PATH}"

if [[ ${OUTCOME_EXIT} -ne ${EXIT_OK} ]]; then
  echo "==> Run failed (exit ${OUTCOME_EXIT}): ${OUTCOME_REASON}"
  SUMMARY_PATCH=$(jq --arg reason "${OUTCOME_REASON}" --argjson exitCode "${OUTCOME_EXIT}" \
    '. + {outcome: {exitCode: $exitCode, reason: $reason}}' "${SUMMARY_PATH}")
else
  SUMMARY_PATCH=$(jq --argjson exitCode "${OUTCOME_EXIT}" '. + {outcome: {exitCode: $exitCode}}' "${SUMMARY_PATH}")
fi
printf '%s\n' "${SUMMARY_PATCH}" > "${SUMMARY_PATH}"

if [[ -n "${RUN_META}" ]]; then
  jq --argjson run "${RUN_META}" '. + {run: $run}' \
    "${SUMMARY_PATH}" > "${SUMMARY_PATH}.tmp" && mv "${SUMMARY_PATH}.tmp" "${SUMMARY_PATH}"
fi

echo "==> Uploading summary (${SUMMARY_PATH}) to RESULT_UPLOAD_URL"
HTTP_CODE=$(
  curl --silent --show-error \
    --request PUT \
    --retry 5 \
    --retry-delay 2 \
    --retry-connrefused \
    --max-time 60 \
    --upload-file "${SUMMARY_PATH}" \
    --write-out '%{http_code}' \
    --output /dev/null \
    "${RESULT_UPLOAD_URL}"
)

if [[ -z "${HTTP_CODE}" || "${HTTP_CODE}" -lt 200 || "${HTTP_CODE}" -ge 300 ]]; then
  echo "ERROR: summary upload failed with HTTP '${HTTP_CODE}'" >&2
  exit ${EXIT_UPLOAD_FAILED}
fi

echo "==> Upload OK (HTTP ${HTTP_CODE})"

if [[ ${OUTCOME_EXIT} -ne ${EXIT_OK} ]]; then
  echo "ERROR: autoconfig did not complete: ${OUTCOME_REASON}" >&2
  exit ${OUTCOME_EXIT}
fi

echo "==> Autoconfig completed successfully"
exit ${EXIT_OK}
