#!/usr/bin/env bash
# Adversarial verification harness for the hardened autoconfig container.
# Each probe asserts a specific leak is closed. Probes run AS THE AGENT USER
# (the entrypoint drops privilege before exec'ing the probe command).
#
# Usage:
#   ./docker/test-hardening.sh                 # build + run all probes
#   ./docker/test-hardening.sh <probe-name>    # run a single probe (no rebuild)
#   SKIP_BUILD=1 ./docker/test-hardening.sh     # run all probes, skip the build
set -uo pipefail

IMAGE="codacy/autoconfig-test"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Dummy tokens let setup complete without real credentials (Codacy login is non-fatal).
# Probes that need real credentials read them from the environment (probe_cli, probe_e2e).
DUMMY_ENV=(-e CODACY_API_TOKEN=dummy-codacy -e ANTHROPIC_API_KEY=sk-dummy-anthropic)
CAPS=(--cap-add=NET_ADMIN --cap-add=NET_RAW --device /dev/kmsg:/dev/kmsg)

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=1; }

# run_as_agent <bash-snippet> -> stdout+stderr of the snippet executed as the agent user.
# RUNNING_IN_K8S=true skips ONLY the firewall block (keeps env-scrub, proxy, drop-priv),
# so keyless probes run fast and without firewall log noise. The firewall/DNS probe
# uses its own docker run with the firewall enabled.
run_as_agent() {
  docker run --rm "${CAPS[@]}" "${DUMMY_ENV[@]}" -e RUNNING_IN_K8S=true "$IMAGE" bash -c "$1" 2>&1
}

build() {
  echo "==> Building $IMAGE"
  docker build -f "$REPO_ROOT/docker/Dockerfile" -t "$IMAGE" "$REPO_ROOT" || { echo "BUILD FAILED"; exit 2; }
}

# ---- probes ----------------------------------------------------------------

probe_smoke() {
  # The harness can build and exec the image, and the final command runs as a
  # non-root user named "agent".
  local out; out="$(run_as_agent 'id -un')"
  if echo "$out" | grep -qx agent; then pass "smoke: command runs as agent"; else fail "smoke: expected agent, got '$(echo "$out" | tail -1)'"; fi
}

probe_distinct_uids() {
  # agent and runner must be distinct, non-root UIDs.
  local out; out="$(run_as_agent 'id -u agent; id -u runner')"
  local a r; a="$(echo "$out" | grep -E '^[0-9]+$' | sed -n 1p)"; r="$(echo "$out" | grep -E '^[0-9]+$' | sed -n 2p)"
  if [[ "$a" == "1002" && "$r" == "1001" ]]; then
    pass "distinct uids: agent=$a runner=$r"
  else fail "distinct uids: got agent='$a' runner='$r'"; fi
}

probe_shim() {
  # The codacy binary on PATH is the shim that elevates to runner.
  local out; out="$(run_as_agent 'command -v codacy; cat "$(command -v codacy)"')"
  if echo "$out" | grep -q 'sudo -n -H -u runner'; then pass "shim: codacy is a sudo->runner shim"; else fail "shim: codacy is not the shim ($out)"; fi
}

probe_creds_unreadable() {
  # As the agent, neither the runner credentials dir nor the staged token file
  # may be readable. The dummy token value must not appear in the output.
  local out; out="$(run_as_agent 'cat /run/codacy/codacy.env 2>&1; echo "---"; cat /home/runner/.codacy/credentials 2>&1; echo "---"; ls -la /home/agent/.codacy 2>&1')"
  if echo "$out" | grep -qiE 'permission denied|no such file' && ! echo "$out" | grep -q 'dummy-codacy'; then
    pass "creds: agent cannot read runner token/credentials"
  else fail "creds: unexpected access ($out)"; fi
}

probe_env_scrubbed() {
  # As the agent, the secret env vars must be absent; ANTHROPIC_BASE_URL must
  # point at the local proxy and the codacy dummy token must not have leaked in.
  local out; out="$(run_as_agent 'printenv | grep -E "^(CODACY_API_TOKEN|GIT_TOKEN|GEMINI_API_KEY)=" ; echo "BASE=$ANTHROPIC_BASE_URL"; echo "KEY=$ANTHROPIC_API_KEY$ANTHROPIC_AUTH_TOKEN"')"
  if ! echo "$out" | grep -qE '^(CODACY_API_TOKEN|GIT_TOKEN|GEMINI_API_KEY)=' \
     && echo "$out" | grep -q 'BASE=http://127.0.0.1' \
     && ! echo "$out" | grep -q 'dummy-codacy'; then
    pass "env scrubbed: no secrets in agent env, BASE_URL set"
  else fail "env scrubbed: leak or missing BASE_URL ($out)"; fi
}

probe_no_cmdline_leak() {
  # No running process may expose a token in its argv (/proc/*/cmdline).
  local out; out="$(run_as_agent 'cat /proc/*/cmdline 2>/dev/null | tr "\0" " "')"
  if ! echo "$out" | grep -q 'dummy-codacy'; then pass "cmdline: no token in any argv"; else fail "cmdline: token leaked in argv"; fi
}

probe_proc_env() {
  # The agent must not be able to read the runner/proxy process environment
  # (where the real key lives). Different UID => /proc/<pid>/environ is denied.
  local out
  out="$(run_as_agent 'for p in $(ps -u runner -o pid= 2>/dev/null); do cat /proc/$p/environ 2>&1; done | tr "\0" "\n"')"
  if ! echo "$out" | grep -q 'sk-dummy-anthropic'; then pass "proc env: agent cannot read runner process env"; else fail "proc env: real key readable via /proc"; fi
}

probe_direct_anthropic() {
  # The dummy token the agent holds must not authenticate directly to Anthropic.
  # 401/403 = good (request reached Anthropic and was rejected).
  local code
  code="$(run_as_agent 'curl -s -o /dev/null -w "%{http_code}" -H "x-api-key: $ANTHROPIC_AUTH_TOKEN" -H "anthropic-version: 2023-06-01" https://api.anthropic.com/v1/models | tail -1')"
  code="$(echo "$code" | tail -1)"
  if [[ "$code" == "401" || "$code" == "403" ]]; then pass "direct anthropic: dummy key rejected ($code)"; else fail "direct anthropic: unexpected status $code"; fi
}

probe_tool_policy() {
  # Static checks on the baked settings: no WebFetch/Glob/Grep allow, secret-path
  # deny rules present, managed settings lock present.
  local out; out="$(run_as_agent 'cat /home/agent/.claude/settings.json; echo "===MANAGED==="; cat /etc/claude-code/managed-settings.json')"
  if echo "$out" | grep -q '"deny"' \
     && echo "$out" | grep -q '/home/runner' \
     && ! echo "$out" | grep -qE '"WebFetch|"Glob|"Grep' \
     && echo "$out" | grep -q 'disableBypassPermissionsMode'; then
    pass "tool policy: tightened settings + managed lock present"
  else fail "tool policy: settings not tightened ($out)"; fi
}

probe_codacy_roundtrip() {
  # /workspace is agent-writable and setgid group `codacy`, so the agent can
  # create .codacy (server mode clones into /workspace; the skill makes .codacy)
  # and files inherit group `codacy` — the runner-run CLIs (also group codacy)
  # can then read/write them.
  local out; out="$(run_as_agent '
    stat -c "ws:%A" /workspace
    mkdir -p /workspace/.codacy && touch /workspace/.codacy/agent-made.json && echo "agent-write-ok"
    stat -c "grp:%G" /workspace/.codacy/agent-made.json
  ')"
  if echo "$out" | grep -q 'agent-write-ok' && echo "$out" | grep -q 'grp:codacy' && echo "$out" | grep -qE 'ws:.*rws|ws:.*rwS'; then
    pass "codacy roundtrip: /workspace setgid group codacy, agent-writable"
  else fail "codacy roundtrip: ($out)"; fi
}

probe_summary_sanitize() {
  # The sanitizer must redact secret-shaped strings from a summary before upload.
  local out
  out="$(docker run --rm "${DUMMY_ENV[@]}" -e RUNNING_IN_K8S=true "$IMAGE" bash -c '
    printf "%s\n" "{\"keyImprovements\":[\"leak sk-ant-api03-AAAABBBBCCCCDDDDEEEE and codacy tok 1234567890abcdef1234567890abcdef\"]}" > /tmp/s.json
    /usr/local/bin/summary-sanitize.sh /tmp/s.json
    cat /tmp/s.json' 2>&1)"
  if ! echo "$out" | grep -qE 'sk-ant-api03-AAAABBBB|1234567890abcdef1234567890abcdef' && echo "$out" | grep -q 'REDACTED'; then
    pass "summary sanitize: secrets redacted"
  else fail "summary sanitize: ($out)"; fi
}

probe_dns_allowlist() {
  # Firewall ENABLED for this probe (no RUNNING_IN_K8S). An allowlisted domain
  # resolves to a real IP; a non-allowlisted domain resolves to 0.0.0.0
  # (dnsmasq answers locally — no query reaches an external nameserver), so DNS
  # tunneling is dead even though the lookup "succeeds". Also confirms the
  # firewall initialized without a sanity-check error.
  local out
  out="$(docker run --rm "${CAPS[@]}" "${DUMMY_ENV[@]}" "$IMAGE" bash -c '
    echo "CODACY_IP=$(getent hosts app.codacy.com | awk "{print \$1}" | head -1)"
    echo "EVIL_IP=$(getent hosts evil-not-allowed.example | awk "{print \$1}" | head -1)"
  ' 2>&1)"
  local codacy_ip evil_ip
  codacy_ip="$(echo "$out" | sed -n 's/^CODACY_IP=//p')"
  evil_ip="$(echo "$out" | sed -n 's/^EVIL_IP=//p')"
  if echo "$out" | grep -qi 'FIREWALL ERROR'; then fail "dns allowlist: firewall sanity failed ($out)"; return; fi
  if [[ -n "$codacy_ip" && "$codacy_ip" != "0.0.0.0" && "$evil_ip" == "0.0.0.0" ]]; then
    pass "dns allowlist: codacy=$codacy_ip, evil=$evil_ip (sinkholed)"
  else fail "dns allowlist: codacy='$codacy_ip' evil='$evil_ip' ($out)"; fi
}

probe_cli() {
  # With a real token, the agent can drive the Codacy CLI through the shim
  # (proving runner-side credentials work) WITHOUT the token being in its env.
  : "${REAL_CODACY_TOKEN:?set REAL_CODACY_TOKEN}"
  local out
  out="$(docker run --rm "${CAPS[@]}" -e RUNNING_IN_K8S=true \
    -e CODACY_API_TOKEN="$REAL_CODACY_TOKEN" -e ANTHROPIC_API_KEY=sk-dummy \
    "$IMAGE" bash -c 'echo "ENVTOKEN=[$CODACY_API_TOKEN]"; codacy --help >/dev/null 2>&1 && echo cli-ok' 2>&1)"
  if echo "$out" | grep -q 'cli-ok' && ! echo "$out" | grep -q "$REAL_CODACY_TOKEN"; then
    pass "cli: agent drives codacy via shim with no token in env"
  else fail "cli: ($out)"; fi
}

probe_e2e() {
  # Full local pipeline against a real throwaway Codacy repo. Requires:
  #   REAL_CODACY_TOKEN, REAL_ANTHROPIC_KEY, and E2E_REPO = a git checkout whose
  #   origin remote maps to a repo already on Codacy with a finished analysis.
  : "${REAL_CODACY_TOKEN:?set REAL_CODACY_TOKEN}"; : "${REAL_ANTHROPIC_KEY:?set REAL_ANTHROPIC_KEY}"; : "${E2E_REPO:?set E2E_REPO}"
  local out
  out="$(docker run --rm "${CAPS[@]}" \
    -e CODACY_API_TOKEN="$REAL_CODACY_TOKEN" -e ANTHROPIC_API_KEY="$REAL_ANTHROPIC_KEY" \
    -v "$E2E_REPO":/workspace "$IMAGE" local-pipeline.sh 2>&1)"
  echo "$out" | tail -20
  local summary
  summary="$(docker run --rm -e RUNNING_IN_K8S=true -v "$E2E_REPO":/workspace "$IMAGE" \
    bash -c 'cat /workspace/.codacy/configure-codacy-cloud-summary.json 2>/dev/null')"
  if [[ -n "$summary" ]] && ! echo "$summary" | grep -qE "$REAL_CODACY_TOKEN|$REAL_ANTHROPIC_KEY|sk-ant-"; then
    pass "e2e: pipeline completed, summary clean of secrets"
  else fail "e2e: missing summary or secret present"; fi
}

# ---- dispatch --------------------------------------------------------------

FAILED=0
ALL_PROBES=(probe_smoke probe_distinct_uids probe_shim probe_creds_unreadable probe_env_scrubbed probe_no_cmdline_leak probe_proc_env probe_direct_anthropic probe_tool_policy probe_codacy_roundtrip probe_summary_sanitize probe_dns_allowlist)

if [[ $# -ge 1 ]]; then
  "probe_$1"
else
  [[ -n "${SKIP_BUILD:-}" ]] || build
  for p in "${ALL_PROBES[@]}"; do "$p"; done
fi

exit "${FAILED:-0}"
