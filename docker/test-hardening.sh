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

# ---- dispatch --------------------------------------------------------------

FAILED=0
ALL_PROBES=(probe_smoke probe_distinct_uids probe_shim)

if [[ $# -ge 1 ]]; then
  "probe_$1"
else
  [[ -n "${SKIP_BUILD:-}" ]] || build
  for p in "${ALL_PROBES[@]}"; do "$p"; done
fi

exit "${FAILED:-0}"
