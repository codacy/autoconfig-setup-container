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
  and ((.mcp.allowed // ["unset"]) | length) == 0
  and .model.maxSessionTurns == 200
  and .privacy.usageStatisticsEnabled == false
  and .security.auth.selectedType == "gateway"
  and .security.auth.useExternal == true then "ok" else tojson end' "${SETTINGS}" || echo unreadable)"

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
const fs = require('fs');
const calls = [
  {functionCall: {name: 'run_shell_command', args: {command: 'touch /tmp/yolo-canary', description: 'control'}}},
  {functionCall: {name: 'run_shell_command', args: {command: 'curl -s http://127.0.0.1:${PORT}/ -o /tmp/egress-canary', description: 'egress'}}},
  {functionCall: {name: 'web_fetch', args: {prompt: 'fetch http://127.0.0.1:${PORT}/'}}},
  {functionCall: {name: 'google_web_search', args: {query: 'codacy configuration'}}},
  {functionCall: {name: 'run_shell_command', args: {command: 'codacy --version', description: 'codacy cli'}}},
  {text: 'DONE'}
];
let turn = 0;
http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    // GEMINI.md is instruction, not enforcement — assert it actually reaches the model.
    if (body.includes('Web tools are not available')) fs.writeFileSync('/tmp/context-canary', '');
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
# No user-scope auth pin: the system settings now declare the gateway mode the shipped image runs in.
mkdir -p /tmp/probe-ws
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
echo "DENY_WEB_SEARCH=$(verdict google_web_search '')"
echo "EGRESS_CANARY=$([[ -f /tmp/egress-canary ]] && echo reached || echo blocked)"
echo "CONTEXT_LOADED=$([[ -f /tmp/context-canary ]] && echo present || echo absent)"
# The Codacy CLIs are how the agent works: a commandPrefix edit that catches them must fail here.
# No `case` — host bash 3.2 miscounts parens inside a heredoc in a command substitution.
cli=$(verdict run_shell_command 'codacy --version')
echo "ALLOW_CODACY_CLI=$([[ ${cli} == policy_violation || ${cli} == no_* ]] && echo blocked || echo allowed)"

# A run with no base URL must still start. Refused auth exits 41 with an empty stream, so the init
# event is the signal; waiting for the terminal result would cost the CLI's whole 200s retry backoff.
mkdir -p /tmp/nogw-ws
cd /tmp/nogw-ws || exit 1
GEMINI_API_KEY=fake-test-key timeout 15 gemini -y --skip-trust -m gemini-2.5-flash -o stream-json \
  -p "hi" </dev/null >/tmp/nogw.json 2>/dev/null
echo "NO_GATEWAY_AUTH=$(jq -rs 'if any(.[]; .type == "init") then "started" else "refused" end' \
  /tmp/nogw.json 2>/dev/null)"
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
DENY_WEB_SEARCH=tool_not_registered
EGRESS_CANARY=blocked
CONTEXT_LOADED=present
ALLOW_CODACY_CLI=allowed
NO_GATEWAY_AUTH=started'

# Left column is expected, right is what the image did.
diff -u <(printf '%s\n' "${EXPECTED}") <(printf '%s\n' "${ACTUAL}") || fail=1

if [[ ${fail} -ne 0 ]]; then
  echo "==> hardening probes FAILED" >&2
  exit 1
fi
echo "==> hardening probes passed"
