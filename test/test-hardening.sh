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

SETTINGS=/home/node/.claude/settings.json
MANAGED=/etc/claude-code/managed-settings.json

# Config assertions only — these read the files the image ships, they do not exercise
# enforcement. Allow must not grow beyond the scoped set, deny must not shrink.
probe_policy_config() {
  local expected_allow expected_deny
  # The skill's own reference files live under commands/, so the agent must be able to read them.
  expected_allow='["Bash(*)","Read(/workspace/**)","Read(/home/node/.claude/commands/**)","Write(/workspace/**)","Edit(/workspace/**)"]'
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
  claude -p "hi" "$@" --output-format stream-json --verbose </dev/null >"${out}" 2>/dev/null &
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

probe_policy_config
probe_no_bypass
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
check "settings.json ships scoped allow list"       POLICY_ALLOW   ok
check "settings.json ships secret/network deny list" POLICY_DENY   ok
check "managed-settings.json installed"             MANAGED_FILE   present
check "managed-settings.json ships bypass lock"     MANAGED_BYPASS disable

echo "[2/2] behavioral — what claude actually does with that config"
check "--dangerously-skip-permissions downgraded"   BYPASS_MODE    default

echo
echo "==> ${pass} passed, ${fail} failed"
[[ ${fail} -eq 0 ]] || exit 1
