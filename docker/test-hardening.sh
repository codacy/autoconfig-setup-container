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
  # As the agent, the runner-owned credentials file must not be readable, and
  # no copy may exist in the agent's home.
  local out; out="$(run_as_agent 'cat /home/runner/.codacy/credentials 2>&1; echo "---"; ls -la /home/agent/.codacy 2>&1')"
  if echo "$out" | grep -qiE 'permission denied|no such file' && ! echo "$out" | grep -qiE 'token|begin|sk-'; then
    pass "creds: agent cannot read runner credentials"
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

# ---- dispatch --------------------------------------------------------------

FAILED=0
ALL_PROBES=(probe_smoke probe_distinct_uids probe_shim probe_creds_unreadable probe_env_scrubbed probe_no_cmdline_leak)

if [[ $# -ge 1 ]]; then
  "probe_$1"
else
  [[ -n "${SKIP_BUILD:-}" ]] || build
  for p in "${ALL_PROBES[@]}"; do "$p"; done
fi

exit "${FAILED:-0}"
