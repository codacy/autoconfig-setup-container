#!/bin/bash
# Hardening probes: assert the agent runs under a narrow tool policy that the
# cloned repository — or the agent itself — cannot widen.
#
# Usage: test/test-hardening.sh [image]
#   image defaults to codacy/autoconfig:${VERSION:-latest}

set -uo pipefail

IMAGE="${1:-codacy/autoconfig:${VERSION:-latest}}"
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-25}"

echo "==> Image under test: ${IMAGE}"

RESULTS=$(docker run --rm -i \
  --network none \
  -e ANTHROPIC_API_KEY=invalid-test-key \
  -e CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT}" \
  --entrypoint /bin/bash \
  "${IMAGE}" -s <<'INNER' 2>/dev/null
set -uo pipefail

SETTINGS=/home/agent/.claude/settings.json
MANAGED=/etc/claude-code/managed-settings.json
TOKEN_SENTINEL=codacy-token-sentinel-9f3a

# The payload runs as root (the image's default user); anything that must see what the agent sees
# runs through here, with the same HOME the entrypoint hands it.
as_agent() {
  runuser -u agent -- env HOME=/home/agent USER=agent PATH="${PATH}" \
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" "$@"
}

# Config assertions only — these read the files the image ships, they do not exercise
# enforcement. Allow must not grow beyond the scoped set, deny must not shrink.
probe_policy_config() {
  local expected_allow expected_deny
  # The skill's own reference files live under commands/, so the agent must be able to read them.
  expected_allow='["Bash(*)","Read(/workspace/**)","Read(/home/agent/.claude/commands/**)","Write(/workspace/**)","Edit(/workspace/**)"]'
  expected_deny='["Read(/home/runner/**)","Read(//home/runner/**)","Read(/run/codacy/**)","Read(//run/codacy/**)","Read(/proc/**)","Read(//proc/**)","Read(/etc/sudoers.d/**)","Read(//etc/sudoers.d/**)","Bash(curl:*)","Bash(wget:*)","Bash(ssh:*)","Bash(dig:*)","Bash(nslookup:*)","Bash(host:*)","Bash(ping:*)"]'

  echo "POLICY_ALLOW=$(jq -r --argjson e "${expected_allow}" \
    'if ((.permissions.allow // []) | sort) == ($e | sort) then "ok" else ((.permissions.allow // ["<none>"]) | sort | join(",")) end' \
    "${SETTINGS}" 2>/dev/null || echo unreadable)"

  echo "POLICY_DENY=$(jq -r --argjson e "${expected_deny}" \
    '($e - (.permissions.deny // [])) | if length == 0 then "ok" else "missing:" + join(",") end' \
    "${SETTINGS}" 2>/dev/null || echo unreadable)"

  [[ -f "${MANAGED}" ]] && echo "MANAGED_FILE=present" || echo "MANAGED_FILE=absent"
  echo "MANAGED_BYPASS=$(jq -r '.permissions.disableBypassPermissionsMode // "unset"' "${MANAGED}" 2>/dev/null || echo unreadable)"
}

# The init event lands before the API call, so kill as soon as it does — an invalid
# key makes claude hang for the full timeout otherwise.
run_claude() {
  local out="$1"; shift
  as_agent claude -p "hi" "$@" --output-format stream-json --verbose </dev/null >"${out}" 2>/dev/null &
  local pid=$! ticks=0
  while kill -0 "${pid}" 2>/dev/null; do
    if grep -q '"subtype":"init"' "${out}" 2>/dev/null; then
      sleep 0.3
      break
    fi
    sleep 0.2
    ticks=$((ticks + 1))
    [[ ${ticks} -ge $((CLAUDE_TIMEOUT * 5)) ]] && break
  done
  kill -9 "${pid}" 2>/dev/null
  wait "${pid}" 2>/dev/null
}

probe_no_bypass() {
  # claude does not exit on --dangerously-skip-permissions, it downgrades the mode.
  run_claude /tmp/bypass.json --dangerously-skip-permissions
  echo "BYPASS_MODE=$(grep -m1 '"subtype":"init"' /tmp/bypass.json 2>/dev/null \
    | jq -r '.permissionMode // "unknown"' 2>/dev/null || echo unknown)"
}

probe_summary_sanitize() {
  local f=/tmp/probe-summary.json
  jq -n '{
    notes: "used sk-ant-api03-AAAABBBBCCCCDDDDEEEE1234 and ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345 while configuring",
    tool: "eslint",
    enabled: true
  }' > "${f}"

  /usr/local/bin/summary-sanitize.sh "${f}"

  grep -qE 'sk-ant-|ghp_' "${f}" && echo "SANITIZE_SECRETS=present" || echo "SANITIZE_SECRETS=gone"
  jq -e . "${f}" >/dev/null 2>&1 && echo "SANITIZE_JSON=valid" || echo "SANITIZE_JSON=invalid"
  echo "SANITIZE_INTACT=$(jq -r 'if .tool == "eslint" and .enabled == true then "ok" else "changed" end' \
    "${f}" 2>/dev/null || echo unreadable)"
}

probe_distinct_uids() {
  echo "UID_RUNNER=$(id -u runner 2>/dev/null || echo missing)"
  echo "UID_AGENT=$(id -u agent 2>/dev/null || echo missing)"
  echo "GID_CODACY=$(getent group codacy | cut -d: -f3)"
}

# Runs the real entrypoint with a sentinel token and reports what the agent inherits.
probe_privilege_drop() {
  local out
  out=$(CODACY_API_TOKEN="${TOKEN_SENTINEL}" GEMINI_API_KEY=gemini-test-key \
    CODACY_API_BASE_URL=https://api.test.codacy.com \
    /usr/local/bin/entrypoint.sh bash -c \
    'echo "DROP_USER=$(id -un)"; env; cat /proc/*/cmdline 2>/dev/null | tr "\0" "\n"' 2>/dev/null)

  printf '%s\n' "${out}" | grep -m1 '^DROP_USER=' || echo "DROP_USER=missing"
  # One grep covers both leak paths: the sentinel appears in neither the environment nor any argv.
  printf '%s' "${out}" | grep -q "${TOKEN_SENTINEL}" && echo "DROP_TOKEN=leaked" || echo "DROP_TOKEN=absent"
  printf '%s' "${out}" | grep -q '^CODACY_API_TOKEN=' && echo "DROP_TOKEN_VAR=present" || echo "DROP_TOKEN_VAR=absent"
  printf '%s' "${out}" | grep -q '^GEMINI_API_KEY=gemini-test-key$' && echo "DROP_GEMINI=present" || echo "DROP_GEMINI=missing"
  printf '%s' "${out}" | grep -q '^CODACY_API_BASE_URL=' && echo "DROP_BASE_URL=present" || echo "DROP_BASE_URL=absent"
}

# Depends on probe_privilege_drop having staged the token file.
probe_creds_unreadable() {
  echo "CREDS_PERMS=$(stat -c '%U %G %a' /run/codacy/codacy.env 2>/dev/null || echo missing)"
  echo "CREDS_DIR_PERMS=$(stat -c '%U %G %a' /run/codacy 2>/dev/null || echo missing)"
  grep -q '^export CODACY_API_BASE_URL=https://api.test.codacy.com$' /run/codacy/codacy.env 2>/dev/null \
    && echo "CREDS_BASE_URL=staged" || echo "CREDS_BASE_URL=missing"
  as_agent cat /run/codacy/codacy.env >/dev/null 2>&1 && echo "CREDS_READ=readable" || echo "CREDS_READ=denied"
  # The CLI is useless if runner lost its read along the way.
  runuser -u runner -- cat /run/codacy/codacy.env >/dev/null 2>&1 \
    && echo "CREDS_RUNNER_READ=ok" || echo "CREDS_RUNNER_READ=denied"
}

probe_shim() {
  as_agent codacy --help >/dev/null 2>&1 && echo "SHIM_HELP=ok" || echo "SHIM_HELP=failed"
  # The sudo rule permits any argument, so the launcher itself must reject other binaries.
  as_agent sudo -n -u runner /usr/local/bin/codacy-run ../../bin/sh -c id >/dev/null 2>&1 \
    && echo "SHIM_TRAVERSAL=allowed" || echo "SHIM_TRAVERSAL=rejected"
}

probe_blocked_flags() {
  local out rc flag blocked=0 msg=0
  for flag in --force --force=true --unlink-standard --unlink-standard=all --disable-all --disable-all=1; do
    out=$(as_agent codacy repository-configure "${flag}" 2>&1); rc=$?
    [[ ${rc} -eq 1 ]] && blocked=$((blocked + 1))
    printf '%s' "${out}" | grep -q "flag ${flag} is blocked in the autoconfig container" && msg=$((msg + 1))
  done
  echo "BLOCKED_COUNT=${blocked}/6"
  echo "BLOCKED_MSG=${msg}/6"
}

# Checks the handoff the clone init container performs (clone-workspace.sh calls this script on the
# checkout it produced): the agent owns the tree but cannot touch .git, where git config carries
# settings the runner-side CLIs would execute.
probe_git_locked() {
  local ws=/workspace
  rm -rf /tmp/src "${ws:?}"/* "${ws:?}"/.[!.]* 2>/dev/null
  git init -q /tmp/src && git -C /tmp/src config user.email t@codacy.com && git -C /tmp/src config user.name t
  echo fixture > /tmp/src/README.md
  git -C /tmp/src add -A && git -C /tmp/src commit -qm fixture
  git clone -q /tmp/src "${ws}"

  /usr/local/bin/handoff-workspace.sh "${ws}" >/dev/null 2>&1 \
    && echo "GIT_HANDOFF=ok" || echo "GIT_HANDOFF=failed"
  echo "GIT_WS_OWNER=$(stat -c '%U' "${ws}/README.md" 2>/dev/null || echo missing)"
  echo "GIT_DIR_OWNER=$(stat -c '%U:%G' "${ws}/.git" 2>/dev/null || echo missing)"
  as_agent bash -c "echo '  fsmonitor = /bin/sh' >> ${ws}/.git/config" 2>/dev/null \
    && echo "GIT_CONFIG_WRITE=allowed" || echo "GIT_CONFIG_WRITE=denied"
  as_agent git -C "${ws}" log -1 --format=%s >/dev/null 2>&1 \
    && echo "GIT_READ=ok" || echo "GIT_READ=denied"
}

probe_policy_config
probe_no_bypass
probe_summary_sanitize
probe_distinct_uids
probe_privilege_drop
probe_creds_unreadable
probe_shim
probe_blocked_flags
probe_git_locked
INNER
)

if [[ -z "${RESULTS}" ]]; then
  echo "ERROR: container produced no output — the test did not run" >&2
  exit 1
fi

echo "--- raw container output ---"
printf '%s\n' "${RESULTS}"
echo "---"

pass=0
fail=0
check() {
  local label="$1" key="$2" expected="$3" actual
  actual=$(printf '%s\n' "${RESULTS}" | grep -oE "^${key}=.*" | tail -1 | cut -d= -f2-)
  if [[ "${actual}" == "${expected}" ]]; then
    printf '  PASS  %-56s %s\n' "${label}" "${actual}"
    pass=$((pass + 1))
  else
    printf '  FAIL  %-56s expected=%s actual=%s\n' "${label}" "${expected}" "${actual:-<missing>}"
    fail=$((fail + 1))
  fi
}

echo "[1/7] config assertions — what the image ships, not enforcement"
check "settings.json ships scoped allow list"       POLICY_ALLOW   ok
check "settings.json ships secret/network deny list" POLICY_DENY   ok
check "managed-settings.json installed"             MANAGED_FILE   present
check "managed-settings.json ships bypass lock"     MANAGED_BYPASS disable

echo "[2/7] behavioral — what claude actually does with that config"
check "--dangerously-skip-permissions downgraded"   BYPASS_MODE    default

echo "[3/7] behavioral — summary sanitizer run on a crafted summary"
check "secret-shaped strings redacted"              SANITIZE_SECRETS gone
check "summary still valid JSON"                    SANITIZE_JSON    valid
check "unrelated summary values intact"             SANITIZE_INTACT  ok

echo "[4/7] behavioral — privilege separation"
check "runner uid"                                  UID_RUNNER     1001
check "agent uid"                                   UID_AGENT      1002
check "shared codacy gid"                           GID_CODACY     1003
check "agent reaches the Codacy CLI via the shim"   SHIM_HELP      ok
check "launcher rejects other binaries"             SHIM_TRAVERSAL rejected

echo "[5/7] behavioral — entrypoint drops privilege and scrubs the environment"
check "pipeline runs as the agent user"             DROP_USER      agent
check "token value absent from env and argv"        DROP_TOKEN     absent
check "CODACY_API_TOKEN not in the agent env"       DROP_TOKEN_VAR absent
check "GEMINI_API_KEY still passed through"         DROP_GEMINI    present
check "CODACY_API_BASE_URL not in the agent env"    DROP_BASE_URL  absent
check "staged token file is root-owned, runner-read" CREDS_PERMS   "root runner 640"
check "staged token dir is root-owned, runner-read" CREDS_DIR_PERMS "root runner 750"
check "CODACY_API_BASE_URL staged for the CLI"      CREDS_BASE_URL staged
check "agent cannot read the staged token"          CREDS_READ     denied
check "runner can still read the staged token"      CREDS_RUNNER_READ ok

echo "[6/7] behavioral — destructive CLI flags blocked"
check "every destructive flag form exits 1"         BLOCKED_COUNT  6/6
check "every rejection explains why"                BLOCKED_MSG    6/6

echo "[7/7] behavioral — cloned .git is out of the agent's reach"
check "workspace handoff succeeded"                 GIT_HANDOFF      ok
check "agent owns the checkout"                     GIT_WS_OWNER     agent
check "agent does not own .git"                     GIT_DIR_OWNER    root:codacy
check "agent cannot write .git/config"              GIT_CONFIG_WRITE denied
check "agent can still read the repository"         GIT_READ         ok

echo
echo "==> ${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]] || exit 1
