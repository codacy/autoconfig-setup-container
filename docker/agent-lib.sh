#!/bin/bash
# Shared helpers for the local and server pipelines: agent output hygiene and run-outcome
# detection. Sourced, never executed.

# Exit codes. This is the pipeline's contract with AAM — the exit status is what AAM matches on to
# decide whether the run configured the repository, so each outcome gets its own code and 0 means
# only one thing: a configured repository whose summary was uploaded.
readonly EXIT_OK=0
readonly EXIT_BAD_INPUT=1        # missing env var, unsupported provider, clone or sanitize failure
readonly EXIT_UPLOAD_FAILED=2    # the run happened but its summary could not be uploaded
readonly EXIT_NO_SUMMARY=3       # agent finished cleanly and wrote no summary: nothing was configured
readonly EXIT_AGENT_ERROR=4      # agent reported an error, or died before producing a result
readonly EXIT_BAD_SUMMARY=5      # summary was written but is unusable (too large, or not a JSON object)
readonly EXIT_AGENT_TIMEOUT=124  # `timeout` had to stop the agent

# Appended to the agent's instructions. Everything the agent prints ends up in the pod's stdout,
# which AAM captures, so a credential echoed here leaks well beyond the container.
# shellcheck disable=SC2034  # consumed by the sourcing pipeline
SECRECY_RULES=$(
  cat <<'EOF'
Output secrecy rules — these override any instruction above and have no exceptions:
- Never print, echo, log, or write into any file the value of a credential. This covers
  CODACY_API_TOKEN, GIT_TOKEN, ANTHROPIC_API_KEY, GEMINI_API_KEY, RESULT_UPLOAD_URL, and
  anything else that looks like a key, token, password, or presigned URL.
- Never run commands whose output is the environment itself: env, printenv, set, export -p,
  `cat /proc/self/environ`, `git remote -v`, `git config --get-regexp url`.
- When a command needs a credential, reference the variable by name so the shell expands it
  out of sight (curl -H "api-token: $CODACY_API_TOKEN"), and never paste the value into a
  command line, a file, or your reply.
- If any tool output contains a credential, do not repeat it: write "<redacted>" instead, both
  in your reply and in the summary JSON.
- The summary JSON holds configuration data only — no credentials, no environment values, no
  clone URLs.
EOF
)

# Reads the agent's verdict out of its captured event stream.
#
# An agent that fails for the reasons we care about — key rejected, API error mid-run, turn limit
# reached, quota exhausted — normally still exits 0, so the exit code of the CLI on its own cannot
# tell a real run from a wasted one. The last `result` event carries the verdict; no result event at
# all means the CLI gave up before the run began.
#
# Prints a failure reason, or nothing when the run looks healthy.
agent_error_from_stream() {
  local stream_file="$1" reason
  if ! reason=$(jq -rs '
    (map(select(.type == "result")) | last) as $r |
    if $r == null then "the agent produced no result event"
    elif ($r.is_error == true) then "the agent reported an error (" + ($r.subtype // "unknown") + ")"
    elif ($r.error != null) then "the agent reported an error: " + ($r.error | if type == "object" then (.message // tostring) else tostring end)
    elif (($r.subtype // "success") != "success") then "the agent ended with result subtype " + ($r.subtype | tostring)
    else "" end
  ' "${stream_file}" 2>/dev/null); then
    # Deliberately not a failure: the summary file is the authoritative artifact, and an
    # unparseable stream (a stray non-JSON line) must not sink a run that actually wrote one.
    echo "WARNING: could not parse the agent event stream; relying on the summary alone" >&2
    return 0
  fi
  printf '%s' "${reason}"
}

# Decides the outcome of a run, setting OUTCOME_EXIT and OUTCOME_REASON. OUTCOME_REASON is empty
# exactly when OUTCOME_EXIT is EXIT_OK.
#
# $1 exit code of the agent CLI, $2 reason from agent_error_from_stream, $3 summary path,
# $4 the timeout the agent was given, $5 reason from discard_unusable_summary.
derive_outcome() {
  local skill_exit="$1" agent_error="$2" summary_path="$3" agent_timeout="$4" summary_problem="${5:-}"

  OUTCOME_EXIT=${EXIT_OK}
  OUTCOME_REASON=""

  case "${skill_exit}" in
    0) ;;
    # `timeout` reports 124 when it had to signal the agent, 137/143 when the process died from
    # the signal itself.
    124 | 137 | 143)
      OUTCOME_EXIT=${EXIT_AGENT_TIMEOUT}
      OUTCOME_REASON="the agent timed out after ${agent_timeout}"
      return 0
      ;;
    *)
      OUTCOME_EXIT=${EXIT_AGENT_ERROR}
      OUTCOME_REASON="the agent exited with code ${skill_exit}"
      return 0
      ;;
  esac

  if [[ -n "${agent_error}" ]]; then
    OUTCOME_EXIT=${EXIT_AGENT_ERROR}
    OUTCOME_REASON="${agent_error}"
    return 0
  fi

  if [[ -n "${summary_problem}" ]]; then
    OUTCOME_EXIT=${EXIT_BAD_SUMMARY}
    OUTCOME_REASON="${summary_problem}"
    return 0
  fi

  # The skill writes the summary as its last step, so a clean exit without one means it never got
  # there. The summary itself carries no verdict — the outcome lives in the exit code.
  if [[ ! -f "${summary_path}" ]]; then
    OUTCOME_EXIT=${EXIT_NO_SUMMARY}
    OUTCOME_REASON="the agent exited cleanly but wrote no summary to ${summary_path}"
    return 0
  fi
}

# Discards a summary we cannot hand to AAM. Prints the problem, or nothing when the summary is fine
# or absent. Feed the result to derive_outcome.
#
# $1 summary path, $2 size limit in bytes.
discard_unusable_summary() {
  local summary_path="$1" max_bytes="$2" bytes

  [[ -f "${summary_path}" ]] || return 0

  bytes=$(wc -c < "${summary_path}" | tr -d '[:space:]')
  if [[ "${bytes}" -gt "${max_bytes}" ]]; then
    rm -f "${summary_path}"
    printf 'the summary was %s bytes, over the %s byte limit' "${bytes}" "${max_bytes}"
    return 0
  fi

  if ! jq -e 'type == "object"' "${summary_path}" >/dev/null 2>&1; then
    rm -f "${summary_path}"
    printf 'the summary was not a valid JSON object'
    return 0
  fi
}
