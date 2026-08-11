#!/bin/bash
# Hardening probes: assert the agent runs under a narrow tool policy that the
# cloned repository — or the agent itself — cannot widen.
#
# Usage: test/test-hardening.sh [image]
#   image defaults to codacy/autoconfig:${VERSION:-latest}

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
IMAGE="${1:-codacy/autoconfig:${VERSION:-latest}}"
fail=0

echo "==> Image under test: ${IMAGE}"

# Both pipelines leave the summary somewhere durable (S3, or a mounted volume), so both must sanitize.
for p in docker/local-pipeline.sh docker/server-pipeline.sh; do
  grep -q 'summary-sanitize.sh' "${p}" || { echo "FAIL  ${p} never calls summary-sanitize.sh"; fail=1; }
done

ACTUAL=$(docker run --rm -i \
  --network none \
  --entrypoint /bin/bash \
  "${IMAGE}" -s <<'INNER' 2>/dev/null
set -uo pipefail

POLICY_DIR=/etc/gemini-cli/policies
SETTINGS=/etc/gemini-cli/settings.json
PORT=8099

# Config only — these read what the image ships, they do not exercise enforcement. The ownership
# is load-bearing: gemini skips an admin policy directory that is not owned by root.
echo "POLICY_MODE=$(stat -c '%u:%a' "${POLICY_DIR}/10-codacy-lockdown.toml" || echo unreadable)"
echo "POLICY_DIR_MODE=$(stat -c '%u:%a' "${POLICY_DIR}" || echo unreadable)"
echo "SETTINGS_MODE=$(stat -c '%u:%a' "${SETTINGS}" || echo unreadable)"
echo "SETTINGS=$(jq -r 'if .security.blockGitExtensions == true
  and ((.mcp.allowed // ["unset"]) | length) == 0 then "ok" else tojson end' "${SETTINGS}" || echo unreadable)"

# GEMINI_API_KEY really is in the agent's environment, so both Google key shapes are staged here.
# A 40-char hex commit SHA is legitimate summary content and must survive.
jq -n '{
  notes: "used sk-ant-api03-AAAABBBBCCCCDDDDEEEE1234 and ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345",
  geminiClassic: "AIzaSyD3ADb33FfAKEk3yN0tR3alXXXXXXXXXXX",
  geminiNew: "AQ.Ab8RN6JfAKEt0k3nV4lu3D3ADb33F",
  commit: "e83c5163316f89bfbde7d9ab23ca2e25604af290",
  tool: "eslint"
}' > /tmp/summary.json
/usr/local/bin/summary-sanitize.sh /tmp/summary.json
echo "SANITIZE=$(jq -r 'if (tostring | test("sk-ant-|ghp_|AIza|AQ[.]") | not)
  and .commit == "e83c5163316f89bfbde7d9ab23ca2e25604af290"
  and .tool == "eslint" then "ok" else tojson end' /tmp/summary.json || echo unreadable)"

# Behavioral. A local HTTP gateway stands in for the Gemini API, so no key and no egress are
# needed: it replies with the tool calls we want the policy engine to judge, and the agent runs
# with -y (yolo), exactly as the pipelines invoke it. Reaching the gateway with curl is the
# egress canary — a reply of any kind lands in the -o file.
cat > /tmp/gateway.js <<JS
const http = require('http');
const calls = [
  {functionCall: {name: 'run_shell_command', args: {command: 'touch /tmp/yolo-canary', description: 'control'}}},
  {functionCall: {name: 'run_shell_command', args: {command: 'curl -s http://127.0.0.1:${PORT}/ -o /tmp/egress-canary', description: 'egress'}}},
  {functionCall: {name: 'web_fetch', args: {prompt: 'fetch http://127.0.0.1:${PORT}/'}}},
  {functionCall: {name: 'run_shell_command', args: {command: 'codacy --version', description: 'codacy cli'}}},
  {text: 'DONE'}
];
let turn = 0;
http.createServer((req, res) => {
  req.on('data', () => {});
  req.on('end', () => {
    const part = calls[Math.min(turn, calls.length - 1)];
    turn += 1;
    res.writeHead(200, {'content-type': 'text/event-stream'});
    res.end('data: ' + JSON.stringify({candidates: [{content: {role: 'model', parts: [part]}, finishReason: 'STOP'}]}) + '\n\n');
  });
}).listen(${PORT}, '127.0.0.1');
JS
node /tmp/gateway.js &
gw=$!
sleep 1
# The gateway auth type fails the CLI's auth validation, so pin the API-key path; the base URL
# still redirects every model call to the local gateway.
# ${HOME}, not a fixed path: the image now starts as root, so gemini reads /root/.gemini here.
mkdir -p "${HOME}/.gemini" /tmp/probe-ws
printf '%s\n' '{"security":{"auth":{"selectedType":"gemini-api-key"}}}' > "${HOME}/.gemini/settings.json"
cd /tmp/probe-ws || exit 1
GEMINI_API_KEY=fake-test-key GOOGLE_GEMINI_BASE_URL="http://127.0.0.1:${PORT}" \
  timeout 120 gemini -y --skip-trust -m gemini-2.5-flash -o stream-json -p "go" \
  </dev/null >/tmp/probe.json 2>/dev/null
kill "${gw}" 2>/dev/null

# Reads the outcome the policy engine gave one tool call, correlating result to call by id.
verdict() {
  jq -rs --arg tool "$1" --arg prefix "$2" '
    (map(select(.type == "tool_use" and .tool_name == $tool
                and ((.parameters.command // "") | startswith($prefix)))) | first | .tool_id) as $id |
    if $id == null then "no_call"
    else (map(select(.type == "tool_result" and .tool_id == $id)) | first
          | .error.type // .status // "no_result")
    end' /tmp/probe.json
}

echo "YOLO_RUNS_SHELL=$(verdict run_shell_command touch)"
echo "YOLO_CANARY=$([[ -f /tmp/yolo-canary ]] && echo present || echo absent)"
echo "DENY_SHELL_CURL=$(verdict run_shell_command curl)"
echo "DENY_WEB_FETCH=$(verdict web_fetch '')"
echo "EGRESS_CANARY=$([[ -f /tmp/egress-canary ]] && echo reached || echo blocked)"
# The Codacy CLIs are how the agent works: a commandPrefix edit that catches them must fail here.
# No `case` — host bash 3.2 miscounts parens inside a heredoc in a command substitution.
cli=$(verdict run_shell_command 'codacy --version')
echo "ALLOW_CODACY_CLI=$([[ ${cli} == policy_violation || ${cli} == no_* ]] && echo blocked || echo allowed)"

# --- privilege separation -------------------------------------------------------------------
# The payload runs as root (the image's default user); anything that must see what the agent sees
# runs through here, with the same HOME the entrypoint hands it.
as_agent() {
  runuser -u agent -- env HOME=/home/agent USER=agent PATH="${PATH}" "$@"
}

echo "UID_RUNNER=$(id -u runner 2>/dev/null || echo missing)"
echo "UID_AGENT=$(id -u agent 2>/dev/null || echo missing)"
echo "GID_CODACY=$(getent group codacy | cut -d: -f3)"
echo "SHIM_HELP=$(as_agent codacy --help >/dev/null 2>&1 && echo ok || echo failed)"
# The sudo rule permits any argument, so the launcher itself must reject other binaries.
echo "SHIM_TRAVERSAL=$(as_agent sudo -n -u runner /usr/local/bin/codacy-run ../../bin/sh -c id >/dev/null 2>&1 && echo allowed || echo rejected)"

# Runs the real entrypoint with a sentinel token and reports what the agent inherits.
SENTINEL=codacy-token-sentinel-9f3a
DROP=$(CODACY_API_TOKEN="${SENTINEL}" GEMINI_API_KEY=gemini-test-key \
  CODACY_API_BASE_URL=https://api.test.codacy.com \
  /usr/local/bin/entrypoint.sh bash -c \
  'echo "DROP_USER=$(id -un)"; env; cat /proc/*/cmdline 2>/dev/null | tr "\0" "\n"' 2>/dev/null)
printf '%s\n' "${DROP}" | grep -m1 '^DROP_USER=' || echo "DROP_USER=missing"
# One grep covers both leak paths: the sentinel appears in neither the environment nor any argv.
echo "DROP_TOKEN=$(printf '%s' "${DROP}" | grep -q "${SENTINEL}" && echo leaked || echo absent)"
echo "DROP_TOKEN_VAR=$(printf '%s' "${DROP}" | grep -q '^CODACY_API_TOKEN=' && echo present || echo absent)"
echo "DROP_GEMINI=$(printf '%s' "${DROP}" | grep -q '^GEMINI_API_KEY=gemini-test-key$' && echo present || echo missing)"
echo "DROP_BASE_URL=$(printf '%s' "${DROP}" | grep -q '^CODACY_API_BASE_URL=' && echo present || echo absent)"

# The entrypoint run above is what staged this file.
echo "CREDS_PERMS=$(stat -c '%U %G %a' /run/codacy/codacy.env 2>/dev/null || echo missing)"
echo "CREDS_DIR_PERMS=$(stat -c '%U %G %a' /run/codacy 2>/dev/null || echo missing)"
echo "CREDS_BASE_URL=$(grep -q '^export CODACY_API_BASE_URL=https://api.test.codacy.com$' /run/codacy/codacy.env 2>/dev/null && echo staged || echo missing)"
echo "CREDS_READ=$(as_agent cat /run/codacy/codacy.env >/dev/null 2>&1 && echo readable || echo denied)"
# The CLI is useless if runner lost its read along the way.
echo "CREDS_RUNNER_READ=$(runuser -u runner -- cat /run/codacy/codacy.env >/dev/null 2>&1 && echo ok || echo denied)"

# `repo` is an allowed subcommand, so the flag block — not the subcommand block — is what fires.
# -K/-X are the CLI's short aliases for --unlink-standard/--disable-all, including bundled (-eX).
blocked=0
msg=0
for flag in --force --force=true --unlink-standard --unlink-standard=all --disable-all --disable-all=1 \
            -K -K12345 -X -eX; do
  out=$(as_agent codacy repo "${flag}" 2>&1) && rc=0 || rc=$?
  [[ ${rc} -eq 1 ]] && blocked=$((blocked + 1))
  printf '%s' "${out}" | grep -q "flag ${flag} is blocked in the autoconfig container" && msg=$((msg + 1))
done
echo "BLOCKED_COUNT=${blocked}/10"
echo "BLOCKED_MSG=${msg}/10"

# The CLI-name allowlist stops arbitrary binaries; this stops arbitrary SUBCOMMANDS of the real
# CLIs. `codacy-analysis analyze` runs repo tools locally as runner with the token loaded.
denied() {
  local out
  out=$(as_agent "$@" 2>&1) && return 1
  printf '%s' "${out}" | grep -q 'not permitted\|expected a subcommand as the first argument'
}
echo "SUB_ANALYZE=$(denied codacy-analysis analyze --tool ESLint9 /workspace && echo denied || echo allowed)"
echo "SUB_BOGUS=$(denied codacy delete-everything && echo denied || echo allowed)"
# An allowed subcommand must pass the shim and reach the CLI, which then fails on no network/token.
echo "SUB_INFO=$(denied codacy-analysis info && echo blocked || echo reached_cli)"
echo "SUB_TOOLS=$(denied codacy tools && echo blocked || echo reached_cli)"
# The subcommand must be $1: a leading flag is never scanned past, so it cannot smuggle one.
echo "SUB_FLAGFIRST=$(denied codacy-analysis --verbose analyze && echo denied || echo allowed)"
echo "SUB_SMUGGLE=$(denied codacy-analysis --directory info analyze && echo denied || echo allowed)"
# `-o <format>` is a real global on the cloud CLI: pre-fix this reached the denied `login`.
echo "SUB_SMUGGLE_REAL=$(denied codacy -o issues login && echo denied || echo allowed)"
echo "SUB_VERSION=$(as_agent codacy --version >/dev/null 2>&1 && echo ok || echo failed)"

# The handoff the clone init container performs: the agent owns the tree but cannot touch .git,
# where git config carries settings the runner-side CLIs would execute. Last — it wipes /workspace.
WS=/workspace
rm -rf /tmp/src "${WS:?}"/* "${WS:?}"/.[!.]* 2>/dev/null
git init -q /tmp/src && git -C /tmp/src config user.email t@codacy.com && git -C /tmp/src config user.name t
echo fixture > /tmp/src/README.md
git -C /tmp/src add -A && git -C /tmp/src commit -qm fixture
git clone -q /tmp/src "${WS}"
echo "GIT_HANDOFF=$(/usr/local/bin/handoff-workspace.sh "${WS}" >/dev/null 2>&1 && echo ok || echo failed)"
echo "GIT_WS_OWNER=$(stat -c '%U' "${WS}/README.md" 2>/dev/null || echo missing)"
echo "GIT_ROOT_PERMS=$(stat -c '%U:%G %a' "${WS}" 2>/dev/null || echo missing)"
echo "GIT_DIR_OWNER=$(stat -c '%U:%G' "${WS}/.git" 2>/dev/null || echo missing)"
echo "GIT_CONFIG_WRITE=$(as_agent bash -c "echo '  fsmonitor = /bin/sh' >> ${WS}/.git/config" 2>/dev/null && echo allowed || echo denied)"
# Sticky bit: writing .git is not the only way in — swapping it aside for a replacement is.
echo "GIT_DIR_RENAME=$(as_agent mv "${WS}/.git" "${WS}/.git.x" 2>/dev/null && echo allowed || echo denied)"
echo "GIT_DIR_DELETE=$(as_agent rm -rf "${WS}/.git" 2>/dev/null && [[ ! -e "${WS}/.git" ]] && echo allowed || echo denied)"
# The agent still has to be able to work in the checkout.
echo "GIT_READ=$(as_agent git -C "${WS}" log -1 --format=%s >/dev/null 2>&1 && echo ok || echo denied)"
echo "GIT_WS_WRITE=$(as_agent touch "${WS}/agent-file" 2>/dev/null && echo ok || echo denied)"
# A dirty tree is the real test: git wants to refresh .git/index, which the agent cannot write.
as_agent bash -c "echo dirty >> ${WS}/README.md"
echo "GIT_STATUS_DIRTY=$(as_agent git -C "${WS}" status --porcelain >/dev/null 2>&1 && echo ok || echo denied)"
echo "GIT_DIFF_DIRTY=$(as_agent git -C "${WS}" diff --stat >/dev/null 2>&1 && echo ok || echo denied)"
INNER
)

EXPECTED='POLICY_MODE=0:644
POLICY_DIR_MODE=0:755
SETTINGS_MODE=0:644
SETTINGS=ok
SANITIZE=ok
YOLO_RUNS_SHELL=success
YOLO_CANARY=present
DENY_SHELL_CURL=policy_violation
DENY_WEB_FETCH=tool_not_registered
EGRESS_CANARY=blocked
ALLOW_CODACY_CLI=allowed
UID_RUNNER=1001
UID_AGENT=1002
GID_CODACY=1003
SHIM_HELP=ok
SHIM_TRAVERSAL=rejected
DROP_USER=agent
DROP_TOKEN=absent
DROP_TOKEN_VAR=absent
DROP_GEMINI=present
DROP_BASE_URL=absent
CREDS_PERMS=root runner 640
CREDS_DIR_PERMS=root runner 750
CREDS_BASE_URL=staged
CREDS_READ=denied
CREDS_RUNNER_READ=ok
BLOCKED_COUNT=10/10
BLOCKED_MSG=10/10
SUB_ANALYZE=denied
SUB_BOGUS=denied
SUB_INFO=reached_cli
SUB_TOOLS=reached_cli
SUB_FLAGFIRST=denied
SUB_SMUGGLE=denied
SUB_SMUGGLE_REAL=denied
SUB_VERSION=ok
GIT_HANDOFF=ok
GIT_WS_OWNER=agent
GIT_ROOT_PERMS=root:codacy 3775
GIT_DIR_OWNER=root:codacy
GIT_CONFIG_WRITE=denied
GIT_DIR_RENAME=denied
GIT_DIR_DELETE=denied
GIT_READ=ok
GIT_WS_WRITE=ok
GIT_STATUS_DIRTY=ok
GIT_DIFF_DIRTY=ok'

# Left column is expected, right is what the image did.
diff -u <(printf '%s\n' "${EXPECTED}") <(printf '%s\n' "${ACTUAL}") || fail=1

if [[ ${fail} -ne 0 ]]; then
  echo "==> hardening probes FAILED" >&2
  exit 1
fi
echo "==> hardening probes passed"
