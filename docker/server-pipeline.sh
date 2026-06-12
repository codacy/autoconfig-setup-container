#!/bin/bash
# Server-side autoconfig entrypoint. Runs in the AAM-launched k8s pod.
# Validates env vars, clones the repo, runs the configure-codacy-cloud skill,
# uploads the summary JSONL to a presigned S3 URL, and exits with the correct status.

set -uo pipefail

REQUIRED_VARS=(
  CODACY_API_TOKEN
  ANTHROPIC_API_KEY
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
  exit 1
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
    exit 1
    ;;
esac

WORKSPACE="${WORKSPACE_DIR:-/workspace}"
SUMMARY_PATH="${AUTOCONFIG_SUMMARY_PATH:-${WORKSPACE}/.codacy/autoconfig-summary.jsonl}"
CLONE_HOST="${CODACY_REPO_CLONE_HOST:-${GIT_HOST_DEFAULT}}"
CLONE_URL="https://${GIT_USERNAME}:${GIT_TOKEN}@${CLONE_HOST}/${CODACY_ORG_NAME}/${CODACY_REPO_NAME}.git"

echo "==> Cloning ${CODACY_PROVIDER}/${CODACY_ORG_NAME}/${CODACY_REPO_NAME} into ${WORKSPACE}"
if ! git clone --depth 1 "${CLONE_URL}" "${WORKSPACE}" 2>&1 | sed "s|${GIT_USERNAME}:[^@]*@|${GIT_USERNAME}:***@|g"; then
  echo "ERROR: git clone failed" >&2
  exit 1
fi

cd "${WORKSPACE}"

# Remove the token from the persisted remote URL so the agent cannot read it
# from .git/config.
git -C "${WORKSPACE}" remote set-url origin \
  "https://${CLONE_HOST}/${CODACY_ORG_NAME}/${CODACY_REPO_NAME}.git" 2>/dev/null || true

mkdir -p "$(dirname "${SUMMARY_PATH}")"

echo "==> Running configure-codacy-cloud"
claude -p "/configure-codacy-cloud" \
  --permission-mode dontAsk \
  --model haiku \
  --output-format stream-json \
  --verbose \
  --include-partial-messages \
  | jq --unbuffered -rj 'select(.type == "stream_event" and .event.delta.type? == "text_delta") | .event.delta.text'
SKILL_EXIT=${PIPESTATUS[0]}
echo

if [[ ! -f "${SUMMARY_PATH}" ]]; then
  echo "==> Skill did not produce ${SUMMARY_PATH}, writing fallback summary"
  if [[ ${SKILL_EXIT} -eq 0 ]]; then
    printf '%s\n' '{"status":"completed","note":"skill exited 0 but did not write a summary"}' > "${SUMMARY_PATH}"
  else
    printf '{"status":"failed","exitCode":%d,"reason":"skill exited non-zero without writing a summary"}\n' "${SKILL_EXIT}" > "${SUMMARY_PATH}"
  fi
fi

echo "==> Sanitizing summary before upload"
/usr/local/bin/summary-sanitize.sh "${SUMMARY_PATH}"

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
  exit 2
fi

echo "==> Upload OK (HTTP ${HTTP_CODE})"

if [[ ${SKILL_EXIT} -ne 0 ]]; then
  echo "ERROR: configure-codacy-cloud exited with code ${SKILL_EXIT}" >&2
  exit ${SKILL_EXIT}
fi

echo "==> Autoconfig completed successfully"
exit 0
