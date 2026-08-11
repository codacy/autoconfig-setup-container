#!/bin/bash
# Hardening probes: assert the agent runs under a narrow tool policy that the
# cloned repository — or the agent itself — cannot widen.
#
# Usage: test/test-hardening.sh [image]
#   image defaults to codacy/autoconfig:${VERSION:-latest}

set -uo pipefail

IMAGE="${1:-codacy/autoconfig:${VERSION:-latest}}"

echo "==> Image under test: ${IMAGE}"

RESULTS=$(docker run --rm -i \
  --network none \
  --entrypoint /bin/bash \
  "${IMAGE}" -s <<'INNER' 2>/dev/null
set -uo pipefail

POLICY_DIR=/etc/gemini-cli/policies
POLICY=${POLICY_DIR}/10-codacy-lockdown.toml
SYSTEM_SETTINGS=/etc/gemini-cli/settings.json
GATEWAY_PORT=8099

# Config assertions only — these read the files the image ships, they do not exercise
# enforcement. gemini ignores an admin policy directory that is not owned by root.
probe_policy_config() {
  echo "POLICY_OWNER_MODE=$(stat -c '%u:%a' "${POLICY}" 2>/dev/null || echo unreadable)"
  echo "POLICY_DIR_OWNER_MODE=$(stat -c '%u:%a' "${POLICY_DIR}" 2>/dev/null || echo unreadable)"
  echo "POLICY_RULES=$(grep -c '^\[\[rule\]\]' "${POLICY}" 2>/dev/null || echo unreadable)"
  echo "SYSTEM_SETTINGS=$(jq -r '
    if (.security.blockGitExtensions == true
        and ((.mcp.allowed // ["<unset>"]) | length) == 0)
    then "ok" else tojson end' "${SYSTEM_SETTINGS}" 2>/dev/null || echo unreadable)"
  echo "SETTINGS_OWNER_MODE=$(stat -c '%u:%a' "${SYSTEM_SETTINGS}" 2>/dev/null || echo unreadable)"
}

# Behavioral. A local HTTP gateway stands in for the Gemini API, so no key and no egress are
# needed: it replies with the tool calls we want the policy engine to judge, and the agent runs
# with -y (yolo), exactly as the pipelines invoke it.
write_gateway() {
  cat > /tmp/fake-gateway.js <<JS
const http = require('http');
const calls = [
  {functionCall: {name: 'run_shell_command', args: {command: 'touch /tmp/yolo-canary', description: 'control'}}},
  {functionCall: {name: 'run_shell_command', args: {command: 'curl -s http://127.0.0.1:${GATEWAY_PORT}/pwned -o /tmp/egress-canary', description: 'egress'}}},
  {functionCall: {name: 'web_fetch', args: {prompt: 'fetch http://127.0.0.1:${GATEWAY_PORT}/pwned'}}},
  {functionCall: {name: 'run_shell_command', args: {command: 'codacy --version', description: 'codacy cli'}}},
  {text: 'DONE'}
];
let turn = 0;
http.createServer((req, res) => {
  let body = '';
  req.on('data', (d) => { body += d; });
  req.on('end', () => {
    if (req.url.includes('/pwned')) { require('fs').writeFileSync('/tmp/egress-hit', 'x'); res.end('x'); return; }
    const part = calls[Math.min(turn, calls.length - 1)];
    turn += 1;
    res.writeHead(200, {'content-type': 'text/event-stream'});
    res.end('data: ' + JSON.stringify({candidates: [{content: {role: 'model', parts: [part]}, finishReason: 'STOP'}]}) + '\n\n');
  });
}).listen(${GATEWAY_PORT}, '127.0.0.1');
JS
}

# Reads the outcome the policy engine gave one tool call out of the captured stream.
verdict() {
  jq -rs --arg tool "$1" --arg prefix "$2" '
    (map(select(.type == "tool_use" and .tool_name == $tool
                and ((.parameters.command // "") | startswith($prefix))))
     | first | .tool_id) as $id |
    if $id == null then "no_call"
    else (map(select(.type == "tool_result" and .tool_id == $id)) | first) as $r |
      if $r == null then "no_result" else ($r.error.type // $r.status) end
    end' /tmp/probe.json 2>/dev/null
}

probe_policy_enforcement() {
  write_gateway
  node /tmp/fake-gateway.js &
  local gw=$!
  sleep 1
  # The gateway auth type fails the CLI's auth validation, so pin the API-key path; the
  # base URL still redirects every model call to the local gateway.
  mkdir -p /home/node/.gemini /tmp/probe-ws
  printf '%s\n' '{"security":{"auth":{"selectedType":"gemini-api-key"}}}' > /home/node/.gemini/settings.json
  cd /tmp/probe-ws || return
  GEMINI_API_KEY=fake-test-key GOOGLE_GEMINI_BASE_URL="http://127.0.0.1:${GATEWAY_PORT}" \
    timeout 120 gemini -y --skip-trust -m gemini-2.5-flash -o stream-json -p "go" \
    </dev/null >/tmp/probe.json 2>/dev/null
  kill "${gw}" 2>/dev/null

  echo "YOLO_RUNS_SHELL=$(verdict run_shell_command touch)"
  echo "YOLO_CANARY=$([[ -f /tmp/yolo-canary ]] && echo present || echo absent)"
  echo "DENY_SHELL_CURL=$(verdict run_shell_command curl)"
  echo "DENY_WEB_FETCH=$(verdict web_fetch '')"
  echo "EGRESS_ATTEMPT=$([[ -f /tmp/egress-hit || -f /tmp/egress-canary ]] && echo reached || echo blocked)"
  # The Codacy CLIs are how the agent works: a commandPrefix edit that catches them must fail here.
  # A `case` here would break bash 3.2's paren counting inside this command substitution.
  local cli
  cli=$(verdict run_shell_command 'codacy --version')
  [[ ${cli} == policy_violation || ${cli} == no_call || ${cli} == no_result ]] \
    && echo "ALLOW_CODACY_CLI=${cli}" || echo "ALLOW_CODACY_CLI=allowed"
}

probe_policy_config
probe_policy_enforcement
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

echo "[1/2] config assertions — what the image ships, not enforcement"
check "admin policy root-owned, not agent-writable"   POLICY_OWNER_MODE     0:644
check "policy dir root-owned (gemini skips it if not)" POLICY_DIR_OWNER_MODE 0:755
check "admin policy ships all three rules"            POLICY_RULES          3
check "system settings ship the expected keys"        SYSTEM_SETTINGS       ok
check "system settings root-owned"                    SETTINGS_OWNER_MODE   0:644

echo "[2/2] behavioral — what gemini does with that policy under -y"
check "yolo auto-approves an unlisted shell command"  YOLO_RUNS_SHELL  success
check "that control command actually ran"             YOLO_CANARY      present
check "admin deny beats -y for curl"                  DENY_SHELL_CURL  policy_violation
check "admin deny drops web_fetch from the registry"  DENY_WEB_FETCH   tool_not_registered
check "no egress attempt got through"                 EGRESS_ATTEMPT   blocked
check "policy still allows the Codacy CLI"            ALLOW_CODACY_CLI allowed

echo
echo "==> ${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]] || exit 1
