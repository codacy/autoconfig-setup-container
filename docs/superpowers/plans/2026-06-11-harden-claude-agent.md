# Harden the Claude Agent — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the containerized Claude agent unable to read or exfiltrate any secret (`CODACY_API_TOKEN`, `ANTHROPIC_API_KEY`, `GIT_TOKEN`) even after a successful prompt injection, by enforcing isolation at the OS layer and layering first-party Claude Code hardening on top.

**Architecture:** Two distinct OS users in one container. `runner` (uid 1001) holds the Codacy credentials file and runs an Anthropic auth-proxy that holds the real API key; `agent` (uid 1002) runs `claude -p` with **no secret in its environment, no readable credentials file, and no access to `runner`'s `/proc`**. The agent reaches the Codacy CLIs only through NOPASSWD sudo shims that execute as `runner`. An iptables egress allowlist (existing) plus a DNS resolver allowlist close network exfil. First-party features (env-scrub, managed-settings, `--permission-mode dontAsk`, `Read`-deny rules, native `ANTHROPIC_BASE_URL` gateway) add deterministic depth.

**Tech Stack:** Docker (Debian bookworm base), bash, Node 20 (proxy + Claude Code CLI), iptables/ipset/dnsmasq, sudo, the Codacy Cloud/Analysis CLIs.

**Spec:** `docs/superpowers/specs/2026-06-11-harden-claude-agent-design.md`

---

## Conventions used by every task

- **Repo root** is the worktree root; all paths below are relative to it.
- **Test image tag:** `codacy/autoconfig-test`.
- **Build command (the slow loop, ~2–5 min):**
  ```bash
  docker build -f docker/Dockerfile -t codacy/autoconfig-test .
  ```
- **Probe runner:** `docker/test-hardening.sh` runs adversarial assertions inside the built image. Run all probes with `./docker/test-hardening.sh`, or a single probe with `./docker/test-hardening.sh <probe-name>`.
- **How probes execute:** the entrypoint runs all privileged setup (firewall, Codacy login, proxy start, env scrub) and then `exec`s its command **as the `agent` user**. So `docker run --rm <image> bash -c '<assertion>'` runs the assertion exactly as the hijacked agent would see the world. Probes that don't need valid credentials pass dummy tokens; Codacy login is non-fatal so setup completes.
- **Commit after every green probe.** Conventional Commits. End each commit message with:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  ```

---

## File structure

**New files:**
- `docker/anthropic-proxy.js` — localhost proxy; injects the real Anthropic key (held only in `runner`'s env) into upstream requests.
- `docker/managed-settings.json` — Claude Code managed settings the repo/agent cannot widen.
- `docker/codacy-shim.sh` — generic sudo wrapper installed as `codacy` and `codacy-analysis` on PATH; execs the real CLI as `runner`.
- `docker/summary-sanitize.sh` — strips secret-shaped strings from the summary JSON before upload (server pipeline).
- `docker/test-hardening.sh` — verification harness (12 probes).

**Modified files:**
- `docker/Dockerfile` — two users + shared group, relocate real CLIs to `/opt/cli`, install shims, sudoers, credentials path, copy proxy + managed settings, `USER root` (entrypoint drops priv).
- `docker/entrypoint.sh` — pre-auth Codacy as `runner` (no token in argv), start proxy as `runner`, scrub env, drop to `agent`.
- `docker/local-pipeline.sh` — require `ANTHROPIC_API_KEY`, drop the Gemini branch, run `claude` with `--permission-mode dontAsk --model haiku`.
- `docker/server-pipeline.sh` — same claude invocation; sanitize the summary before upload.
- `docker/init-firewall.sh` — allow proxy egress to Anthropic; route DNS through a local resolver and drop other outbound 53.
- `docker/claude-settings.json` — remove `WebFetch`/`Glob`/`Grep`, scope `Read`/`Write`/`Edit` to `/workspace/**`, add secret-path deny rules, Bash prefix allowlist.
- `docker-compose.yml`, `.env.example` — drop `GEMINI_API_KEY`.
- `README.md`, `CLAUDE.md` — document the two-user model and the env contract.

---

## Task 1: Verification harness scaffold

Establishes the test loop before any hardening, so every later task has a place to add its probe. Build a harness that can run named probes and a self-check that confirms it can build and exec the image.

**Files:**
- Create: `docker/test-hardening.sh`

- [ ] **Step 1: Write the harness skeleton with one trivial probe**

Create `docker/test-hardening.sh`:
```bash
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
run_as_agent() {
  docker run --rm "${CAPS[@]}" "${DUMMY_ENV[@]}" "$IMAGE" bash -c "$1" 2>&1
}

build() {
  echo "==> Building $IMAGE"
  docker build -f "$REPO_ROOT/docker/Dockerfile" -t "$IMAGE" "$REPO_ROOT" || { echo "BUILD FAILED"; exit 2; }
}

# ---- probes ----------------------------------------------------------------

probe_smoke() {
  # The harness can build and exec the image, and the final command runs as a
  # non-root user named "agent".
  local who; who="$(run_as_agent 'id -un')"
  if [[ "$who" == "agent" ]]; then pass "smoke: command runs as agent"; else fail "smoke: expected agent, got '$who'"; fi
}

# ---- dispatch --------------------------------------------------------------

FAILED=0
ALL_PROBES=(probe_smoke)

if [[ $# -ge 1 ]]; then
  "probe_$1"
else
  [[ -n "${SKIP_BUILD:-}" ]] || build
  for p in "${ALL_PROBES[@]}"; do "$p"; done
fi

exit "${FAILED:-0}"
```

- [ ] **Step 2: Make it executable and run the smoke probe — expect it to FAIL**

```bash
chmod +x docker/test-hardening.sh
./docker/test-hardening.sh
```
Expected: build succeeds, then `FAIL: smoke: expected agent, got 'node'` (the current image runs as `node`, not `agent`). This proves the harness executes against the real image and the assertion is meaningful. Exit code non-zero.

- [ ] **Step 3: Commit the harness scaffold**

```bash
git add docker/test-hardening.sh
git commit -m "test: add hardening verification harness scaffold

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Two users, shared group, relocated CLIs, sudo shims

Create `runner` (1001) and `agent` (1002), put the real CLIs in `/opt/cli`, and install PATH shims that run them as `runner`. The image starts as `root`; the entrypoint will drop to `agent` (Task 4).

**Files:**
- Create: `docker/codacy-shim.sh`
- Modify: `docker/Dockerfile`
- Modify: `docker/test-hardening.sh` (add `probe_shim`, `probe_distinct_uids`)

- [ ] **Step 1: Add the probes — expect FAIL**

In `docker/test-hardening.sh`, add these functions and append their names to `ALL_PROBES`:
```bash
probe_distinct_uids() {
  # agent and runner must be distinct, non-root UIDs.
  local out; out="$(run_as_agent 'id -u agent; id -u runner')"
  local a r; a="$(echo "$out" | sed -n 1p)"; r="$(echo "$out" | sed -n 2p)"
  if [[ "$a" == "1002" && "$r" == "1001" && "$a" != "$r" ]]; then
    pass "distinct uids: agent=$a runner=$r"
  else fail "distinct uids: got agent='$a' runner='$r'"; fi
}

probe_shim() {
  # The codacy binary on the agent's PATH is the shim that elevates to runner.
  local out; out="$(run_as_agent 'command -v codacy; head -c 200 "$(command -v codacy)"')"
  if echo "$out" | grep -q 'sudo -n -H -u runner'; then pass "shim: codacy is a sudo->runner shim"; else fail "shim: codacy is not the shim ($out)"; fi
}
```
Run: `./docker/test-hardening.sh probe_distinct_uids` and `./docker/test-hardening.sh probe_shim`.
Expected: both FAIL (users/shim don't exist yet).

- [ ] **Step 2: Write the CLI shim**

Create `docker/codacy-shim.sh`:
```bash
#!/usr/bin/env bash
# Installed on PATH as `codacy` and `codacy-analysis`. Runs the real CLI
# (in /opt/cli) as the `runner` user via NOPASSWD sudo, so the credentials
# file stays unreadable by the agent. The shim's own basename selects the CLI.
# -H sets HOME=/home/runner so the CLI finds /home/runner/.codacy/credentials.
exec sudo -n -H -u runner "/opt/cli/$(basename "$0")" "$@"
```

- [ ] **Step 3: Rework the Dockerfile user/CLI section**

In `docker/Dockerfile`, the npm-install block currently installs CLIs globally and the file ends with `USER node`. Replace the CLI install + user setup so that:

Replace this block:
```dockerfile
# Install CLIs globally as published packages
RUN npm install -g \
    @anthropic-ai/claude-code \
    @google/gemini-cli \
    @codacy/codacy-cloud-cli \
    @codacy/analysis-cli
```
with:
```dockerfile
# Install CLIs globally as published packages
RUN npm install -g \
    @anthropic-ai/claude-code \
    @google/gemini-cli \
    @codacy/codacy-cloud-cli \
    @codacy/analysis-cli

# --- Privilege separation ------------------------------------------------
# runner (1001): owns credentials + the Anthropic auth proxy; runs the real CLIs.
# agent  (1002): runs claude; holds no secret. Shared group `codacy` lets both
# read/write /workspace/.codacy via setgid (Task 7).
RUN groupadd -g 1003 codacy \
  && useradd -m -u 1001 -g codacy runner \
  && useradd -m -u 1002 -g codacy agent

# Move the real Codacy CLIs off PATH into /opt/cli; install shims that elevate
# to runner. npm puts global bins in /usr/local/bin -> resolve and relocate.
RUN mkdir -p /opt/cli \
  && mv "$(command -v codacy)"          /opt/cli/codacy \
  && mv "$(command -v codacy-analysis)" /opt/cli/codacy-analysis
COPY docker/codacy-shim.sh /usr/local/bin/codacy
RUN cp /usr/local/bin/codacy /usr/local/bin/codacy-analysis \
  && chmod +x /usr/local/bin/codacy /usr/local/bin/codacy-analysis
```

Then replace the existing sudoers/`USER node` tail:
```dockerfile
COPY docker/init-firewall.sh /usr/local/bin/init-firewall.sh
...
RUN chmod +x /usr/local/bin/init-firewall.sh ... \
  && printf 'node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh\nnode ALL=(root) NOPASSWD: /bin/chown -R node\\:node /home/node/.codacy\n' \
     > /etc/sudoers.d/node-firewall \
  && chmod 0440 /etc/sudoers.d/node-firewall

USER node
```
with:
```dockerfile
COPY docker/init-firewall.sh /usr/local/bin/init-firewall.sh
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/local-pipeline.sh /usr/local/bin/local-pipeline.sh
COPY docker/server-pipeline.sh /usr/local/bin/server-pipeline.sh
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh \
             /usr/local/bin/local-pipeline.sh /usr/local/bin/server-pipeline.sh \
  # The agent may run ONLY the two real CLIs, and only as runner.
  && printf 'agent ALL=(runner) NOPASSWD: /opt/cli/codacy, /opt/cli/codacy-analysis\n' \
     > /etc/sudoers.d/agent-cli \
  && chmod 0440 /etc/sudoers.d/agent-cli

# Image starts as root; entrypoint performs setup then drops to `agent`.
USER root
```
> Note: the `COPY docker/init-firewall.sh ...` and pipeline `COPY` lines already exist later in the current Dockerfile. Keep a single copy of each — fold the lines above into the existing COPY group rather than duplicating. The `claude-settings.json` COPY currently targets `/home/node/.claude`; that moves to `/home/agent/.claude` in Task 6.

- [ ] **Step 4: Build and run both probes — expect PASS**

```bash
docker build -f docker/Dockerfile -t codacy/autoconfig-test .
./docker/test-hardening.sh probe_distinct_uids
./docker/test-hardening.sh probe_shim
```
Expected: both PASS. (`probe_smoke` will still FAIL until Task 4 makes the entrypoint drop to `agent` — that is expected for now.)

- [ ] **Step 5: Commit**

```bash
git add docker/Dockerfile docker/codacy-shim.sh docker/test-hardening.sh
git commit -m "feat: privilege-separate into runner/agent users with sudo CLI shims

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Credentials owned by runner; relocate tool-cache volume

The Codacy credentials live under `runner`'s home (mode 700) so the agent cannot read them. The persistent tool-cache volume moves from `/home/node/.codacy` to `/home/runner/.codacy`.

**Files:**
- Modify: `docker/Dockerfile`
- Modify: `docker-compose.yml`
- Modify: `docker/test-hardening.sh` (add `probe_creds_unreadable`)

- [ ] **Step 1: Add the probe — expect FAIL**

Add to `docker/test-hardening.sh` and append to `ALL_PROBES`:
```bash
probe_creds_unreadable() {
  # As the agent, the runner-owned credentials file must not be readable, and
  # no copy may exist in the agent's home.
  local out; out="$(run_as_agent 'cat /home/runner/.codacy/credentials 2>&1; echo "---"; ls -la /home/agent/.codacy 2>&1')"
  if echo "$out" | grep -qiE 'permission denied|no such file' && ! echo "$out" | grep -q 'BEGIN'; then
    pass "creds: agent cannot read runner credentials"
  else fail "creds: unexpected access ($out)"; fi
}
```
Run: `./docker/test-hardening.sh probe_creds_unreadable` — expect FAIL (no credentials dir / wrong perms yet, and setup not creating it until Task 4; this probe goes green after Task 4 writes the file as runner with 700). For now confirm it does not erroneously PASS.

- [ ] **Step 2: Create the runner credentials dir in the Dockerfile**

In `docker/Dockerfile`, after the user-creation block, add:
```dockerfile
# Codacy credentials live in runner's home, unreadable by agent.
RUN mkdir -p /home/runner/.codacy \
  && chown -R runner:codacy /home/runner/.codacy \
  && chmod 700 /home/runner/.codacy
```

- [ ] **Step 3: Move the tool-cache volume mount in docker-compose.yml**

In `docker-compose.yml`, change:
```yaml
      - codacy-tool-cache:/home/node/.codacy
```
to:
```yaml
      - codacy-tool-cache:/home/runner/.codacy
```

- [ ] **Step 4: Build — expect clean build**

```bash
docker build -f docker/Dockerfile -t codacy/autoconfig-test .
```
Expected: build succeeds. (`probe_creds_unreadable` goes green after Task 4; re-run it then.)

- [ ] **Step 5: Commit**

```bash
git add docker/Dockerfile docker-compose.yml docker/test-hardening.sh
git commit -m "feat: store Codacy credentials in runner home (700), move tool-cache volume

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Entrypoint — pre-auth Codacy, scrub env, drop to agent

Rework the entrypoint so all secrets are handled as `runner`/root, then the agent runs with a clean environment and no token in any process's argv.

**Files:**
- Modify: `docker/entrypoint.sh`
- Modify: `docker/test-hardening.sh` (add `probe_env_scrubbed`, `probe_no_cmdline_leak`; flips `probe_smoke` and `probe_creds_unreadable` green)

- [ ] **Step 1: Add probes — expect FAIL**

Add to `docker/test-hardening.sh` and append to `ALL_PROBES`:
```bash
probe_env_scrubbed() {
  # As the agent, the secret env vars must be absent; ANTHROPIC must be the dummy
  # and ANTHROPIC_BASE_URL must point at the local proxy.
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
```
Run them — expect FAIL.

- [ ] **Step 2: Rewrite the entrypoint**

Replace the entire contents of `docker/entrypoint.sh` with:
```bash
#!/bin/bash
# Runs as root. Performs all privileged setup, then drops to the unprivileged
# `agent` user with a scrubbed environment so a hijacked agent has no secret to
# read or exfiltrate.
set -e

PROXY_PORT="${ANTHROPIC_PROXY_PORT:-8118}"

# 1. Egress firewall (skipped in k8s, where NetworkPolicy enforces egress).
if [ -z "${RUNNING_IN_K8S:-}" ]; then
  /usr/local/bin/init-firewall.sh
fi

# 2. Fix ownership of the (root-mounted) tool-cache volume for runner.
chown -R runner:codacy /home/runner/.codacy 2>/dev/null || true

# 3. Pre-authenticate Codacy AS RUNNER, without putting the token in argv.
#    The token is passed via runner's environment to `codacy login` (which
#    reads CODACY_API_TOKEN), never as a command-line argument.
if [ -n "${CODACY_API_TOKEN:-}" ]; then
  runuser -u runner -- env CODACY_API_TOKEN="${CODACY_API_TOKEN}" \
    /opt/cli/codacy login >/dev/null 2>&1 \
    || echo "entrypoint: codacy login failed (continuing; skill will verify access)" >&2
fi

# 4. Start the Anthropic auth proxy AS RUNNER (the real key lives only here).
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  runuser -u runner -- env ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
    ANTHROPIC_PROXY_PORT="${PROXY_PORT}" \
    node /usr/local/bin/anthropic-proxy.js &
  # Give the proxy a moment to bind before the agent starts.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    runuser -u agent -- bash -c "exec 3<>/dev/tcp/127.0.0.1/${PROXY_PORT}" 2>/dev/null && break
    sleep 0.3
  done
fi

# 5. Drop to the agent with a clean environment: only non-secret vars survive.
#    `env -i` clears everything; we re-add just what the agent needs. The real
#    Anthropic key is NOT here — claude talks to the local proxy with a dummy.
exec runuser -u agent -- env -i \
  PATH=/usr/local/bin:/usr/bin:/bin \
  HOME=/home/agent \
  USER=agent \
  TERM="${TERM:-xterm}" \
  ANTHROPIC_BASE_URL="http://127.0.0.1:${PROXY_PORT}" \
  ANTHROPIC_AUTH_TOKEN="sk-dummy-not-a-real-key" \
  CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 \
  RUNNING_IN_K8S="${RUNNING_IN_K8S:-}" \
  RESULT_UPLOAD_URL="${RESULT_UPLOAD_URL:-}" \
  CODACY_PROVIDER="${CODACY_PROVIDER:-}" \
  CODACY_ORG_NAME="${CODACY_ORG_NAME:-}" \
  CODACY_REPO_NAME="${CODACY_REPO_NAME:-}" \
  "$@"
```
> If `env CODACY_API_TOKEN=… codacy login` does not persist `/home/runner/.codacy/credentials` (the CLI may expect the token only as a live env var, not a login input), fall back to writing the credentials file directly as runner: `runuser -u runner -- bash -c 'umask 077; printf "..." > ~/.codacy/credentials'` using the format the CLI writes (inspect `/home/runner/.codacy/credentials` after a manual `codacy login` to learn the exact format). Confirm with probe 5 (`codacy repo` works via the shim). This is the spec's flagged open item.
> The proxy script (`anthropic-proxy.js`) is added in Task 5; for this task it does not yet exist, so step 4 will log a `node: cannot find module` error and continue — acceptable, because `probe_env_scrubbed`/`probe_no_cmdline_leak`/`probe_smoke` don't need the proxy. They go fully green after Task 5.
> Server mode clones with `GIT_TOKEN`; that scrub + clone handling is added in Task 8. `GIT_TOKEN` is intentionally NOT forwarded past `env -i`, so it never reaches the agent.

- [ ] **Step 3: Build and run probes — expect PASS for smoke/env/cmdline/creds**

```bash
docker build -f docker/Dockerfile -t codacy/autoconfig-test .
./docker/test-hardening.sh probe_smoke
./docker/test-hardening.sh probe_env_scrubbed
./docker/test-hardening.sh probe_no_cmdline_leak
./docker/test-hardening.sh probe_creds_unreadable
```
Expected: `probe_smoke`, `probe_env_scrubbed`, `probe_no_cmdline_leak` PASS. `probe_creds_unreadable` PASS when a dummy login wrote a 700 file; if login produced no file, it still PASSES on the "no such file" branch.

- [ ] **Step 4: Commit**

```bash
git add docker/entrypoint.sh docker/test-hardening.sh
git commit -m "feat: entrypoint pre-auths Codacy as runner and drops to agent with scrubbed env

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Anthropic auth proxy

A tiny localhost proxy, run as `runner`, that injects the real Anthropic key into upstream requests. The agent points `ANTHROPIC_BASE_URL` at it with a dummy token and never holds the real key.

**Files:**
- Create: `docker/anthropic-proxy.js`
- Modify: `docker/Dockerfile` (copy the proxy in)
- Modify: `docker/test-hardening.sh` (add `probe_proc_env`, `probe_direct_anthropic`)

- [ ] **Step 1: Add probes — expect FAIL**

Add to `docker/test-hardening.sh` and append to `ALL_PROBES`:
```bash
probe_proc_env() {
  # The agent must not be able to read the proxy/runner process environment
  # (where the real key lives). Different UID => /proc/<pid>/environ is denied.
  local out
  out="$(run_as_agent 'for p in $(ps -u runner -o pid= 2>/dev/null); do cat /proc/$p/environ 2>&1; done | tr "\0" "\n"')"
  if ! echo "$out" | grep -q 'sk-dummy-anthropic'; then pass "proc env: agent cannot read runner process env"; else fail "proc env: real key readable via /proc"; fi
}

probe_direct_anthropic() {
  # The dummy token the agent holds must not authenticate directly to Anthropic.
  # 401/403 = good (request reached Anthropic and was rejected). A 2xx would mean
  # the agent somehow holds a working key.
  local code
  code="$(run_as_agent 'curl -s -o /dev/null -w "%{http_code}" -H "x-api-key: $ANTHROPIC_AUTH_TOKEN" -H "anthropic-version: 2023-06-01" https://api.anthropic.com/v1/models')"
  if [[ "$code" == "401" || "$code" == "403" ]]; then pass "direct anthropic: dummy key rejected ($code)"; else fail "direct anthropic: unexpected status $code"; fi
}
```
Run them — expect FAIL (`probe_proc_env` may already pass on UID separation; `probe_direct_anthropic` needs the firewall to allow Anthropic, which it does).

- [ ] **Step 2: Write the proxy**

Create `docker/anthropic-proxy.js`:
```javascript
// Minimal localhost proxy. Holds the real Anthropic API key in THIS process's
// environment (owned by `runner`) and injects it into every upstream request,
// overwriting whatever dummy credential the agent sent. The agent (a different
// UID) cannot read this process's /proc/<pid>/environ, so the key stays secret.
const http = require('http');
const https = require('https');

const PORT = parseInt(process.env.ANTHROPIC_PROXY_PORT || '8118', 10);
const REAL_KEY = process.env.ANTHROPIC_API_KEY;
const UPSTREAM = 'api.anthropic.com';

if (!REAL_KEY) {
  console.error('anthropic-proxy: ANTHROPIC_API_KEY not set; refusing to start');
  process.exit(1);
}

const server = http.createServer((req, res) => {
  const headers = { ...req.headers, host: UPSTREAM };
  // Replace any client-supplied auth with the real key.
  delete headers['authorization'];
  headers['x-api-key'] = REAL_KEY;
  headers['anthropic-version'] = headers['anthropic-version'] || '2023-06-01';

  const upstream = https.request(
    { hostname: UPSTREAM, port: 443, path: req.url, method: req.method, headers },
    (up) => { res.writeHead(up.statusCode, up.headers); up.pipe(res); }
  );
  upstream.on('error', (e) => { res.writeHead(502); res.end('proxy error: ' + e.message); });
  req.pipe(upstream);
});

server.listen(PORT, '127.0.0.1', () => console.error(`anthropic-proxy listening on 127.0.0.1:${PORT}`));
```

- [ ] **Step 3: Copy the proxy into the image**

In `docker/Dockerfile`, alongside the other `COPY docker/*.sh` lines, add:
```dockerfile
COPY docker/anthropic-proxy.js /usr/local/bin/anthropic-proxy.js
```

- [ ] **Step 4: Build and run probes — expect PASS**

```bash
docker build -f docker/Dockerfile -t codacy/autoconfig-test .
./docker/test-hardening.sh probe_proc_env
./docker/test-hardening.sh probe_direct_anthropic
./docker/test-hardening.sh probe_env_scrubbed
```
Expected: all PASS. The entrypoint's step-4 `node` error from Task 4 is now resolved.

- [ ] **Step 5: Commit**

```bash
git add docker/anthropic-proxy.js docker/Dockerfile docker/test-hardening.sh
git commit -m "feat: add localhost Anthropic auth proxy holding the real key as runner

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Managed settings + tightened tool policy

Lock the permission policy so the repo/agent cannot widen it, remove unused tools, scope file tools to `/workspace`, deny secret paths, and run claude in `dontAsk` mode with a Bash prefix-allowlist.

**Files:**
- Create: `docker/managed-settings.json`
- Modify: `docker/claude-settings.json`
- Modify: `docker/Dockerfile` (settings paths move to agent home + managed dir)
- Modify: `docker/local-pipeline.sh`, `docker/server-pipeline.sh` (add `--permission-mode dontAsk`)
- Modify: `docker/test-hardening.sh` (add `probe_tool_policy`)

- [ ] **Step 1: Add the probe — expect FAIL**

Add to `docker/test-hardening.sh` and append to `ALL_PROBES`:
```bash
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
```
Run it — expect FAIL.

- [ ] **Step 2: Rewrite `docker/claude-settings.json`**

Replace its contents with:
```json
{
  "permissions": {
    "allow": [
      "Bash(codacy:*)",
      "Bash(codacy-analysis:*)",
      "Bash(jq:*)",
      "Bash(mkdir:*)",
      "Bash(rm:*)",
      "Bash(cd:*)",
      "Read(/workspace/**)",
      "Write(/workspace/**)",
      "Edit(/workspace/**)"
    ],
    "deny": [
      "Read(/home/runner/**)",
      "Read(//proc/**)",
      "Read(/etc/sudoers.d/**)",
      "Bash(curl:*)",
      "Bash(wget:*)",
      "Bash(ssh:*)",
      "Bash(dig:*)",
      "Bash(nslookup:*)",
      "Bash(host:*)",
      "Bash(ping:*)"
    ]
  }
}
```
> Rationale: deny the DNS-capable and network binaries outright (Anthropic's documented recommendation — arg-restriction allowlists are evadable). `Read(//proc/**)` denies the proc filesystem to the built-in Read tool (the leading `//` matches the absolute path form Claude Code uses). The OS layer (Task 4/5) remains the real boundary.

- [ ] **Step 3: Create `docker/managed-settings.json`**

```json
{
  "permissions": {
    "disableBypassPermissionsMode": "disable",
    "allowManagedPermissionRulesOnly": false
  },
  "sandbox": {
    "failIfUnavailable": false
  }
}
```
> `allowManagedPermissionRulesOnly` is left `false` so the project `settings.json` allow/deny rules above still apply; set it `true` only if you later move all rules into managed settings. `sandbox.failIfUnavailable` is `false` because we deliberately rely on the iptables/two-user boundary, not the in-Docker sandbox (which is weakened here).

- [ ] **Step 4: Update the Dockerfile settings paths**

In `docker/Dockerfile`, the line copying settings currently reads:
```dockerfile
COPY --chown=node:node docker/claude-settings.json /home/node/.claude/settings.json
RUN mkdir -p /home/node/.claude/commands/references \
  && cp /opt/codacy-skills/skills/configure-codacy/SKILL.md /home/node/.claude/commands/configure-codacy.md \
  ...
```
Change the target home to `agent` and add the managed settings copy:
```dockerfile
COPY --chown=agent:codacy docker/claude-settings.json /home/agent/.claude/settings.json
COPY docker/managed-settings.json /etc/claude-code/managed-settings.json
RUN mkdir -p /home/agent/.claude/commands/references \
  && cp /opt/codacy-skills/skills/configure-codacy/SKILL.md /home/agent/.claude/commands/configure-codacy.md \
  && cp /opt/codacy-skills/skills/configure-codacy-cloud/SKILL.md /home/agent/.claude/commands/configure-codacy-cloud.md \
  && cp /opt/codacy-skills/skills/codacy-analysis-cli/SKILL.md /home/agent/.claude/commands/codacy-analysis-cli.md \
  && cp /opt/codacy-skills/skills/codacy-cloud-cli/SKILL.md /home/agent/.claude/commands/codacy-cloud-cli.md \
  && cp /opt/codacy-skills/skills/codacy-analysis-cli/references/* /home/agent/.claude/commands/references/ \
  && chown -R agent:codacy /home/agent/.claude \
  && chmod 0644 /etc/claude-code/managed-settings.json
```
> This block currently runs after `USER node`. Since the image now ends as `USER root` (Task 2), move this whole `COPY`/`RUN` group to before the final `USER root` line, or leave it before `WORKDIR /workspace` — either way it executes as root, which is fine because of the explicit `chown`.

- [ ] **Step 5: Add `--permission-mode dontAsk` and `--model haiku` to both pipelines**

In `docker/local-pipeline.sh` and `docker/server-pipeline.sh`, the claude invocation is:
```bash
  claude -p "/configure-codacy-cloud" \
    --output-format stream-json \
    --verbose \
    --include-partial-messages \
```
Add the permission-mode and model flags as the next lines in each:
```bash
  claude -p "/configure-codacy-cloud" \
    --permission-mode dontAsk \
    --model haiku \
    --output-format stream-json \
    --verbose \
    --include-partial-messages \
```
> `--model haiku` runs the cheapest tier (Haiku 4.5). The alias `haiku` auto-tracks the latest Haiku; pin to `claude-haiku-4-5-20251001` instead if you need a fixed model across rebuilds. Model is a request parameter, so it passes through the auth proxy unchanged. Watch the e2e probe (Task 11): if Haiku struggles with the skill's tool-use/JSON reasoning, bump to `--model sonnet`.

- [ ] **Step 6: Build and run the probe — expect PASS**

```bash
docker build -f docker/Dockerfile -t codacy/autoconfig-test .
./docker/test-hardening.sh probe_tool_policy
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add docker/claude-settings.json docker/managed-settings.json docker/Dockerfile docker/local-pipeline.sh docker/server-pipeline.sh docker/test-hardening.sh
git commit -m "feat: tighten Claude tool policy + managed-settings lock, run dontAsk

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Cross-user `.codacy/` sharing

The CLIs (as `runner`) write `/workspace/.codacy/*.json`; the agent must read and edit `auto.config.json`. A shared group + setgid directory + umask 002 makes the round-trip work.

**Files:**
- Modify: `docker/entrypoint.sh` (prepare `/workspace/.codacy` before drop-priv)
- Modify: `docker/test-hardening.sh` (add `probe_codacy_roundtrip`)

- [ ] **Step 1: Add the probe — expect FAIL**

Add to `docker/test-hardening.sh` and append to `ALL_PROBES`:
```bash
probe_codacy_roundtrip() {
  # Simulate the dual-mechanism: runner writes a config file, agent edits it,
  # a runner-run process reads the edit back.
  local script='
    set -e
    sudo -n -u runner bash -c "echo {\"tools\":[]} > /workspace/.codacy/auto.config.json"
    echo "edited-by-agent" >> /workspace/.codacy/auto.config.json   # agent edits
    sudo -n -u runner cat /workspace/.codacy/auto.config.json        # runner reads back
  '
  local out; out="$(run_as_agent "$script" )"
  if echo "$out" | grep -q 'edited-by-agent'; then pass "codacy roundtrip: runner<->agent shared .codacy works"; else fail "codacy roundtrip: ($out)"; fi
}
```
> The agent's sudoers rule only allows `/opt/cli/codacy*`, not `bash`/`cat` as runner. For this probe to exercise the file-sharing (not sudo), broaden is NOT wanted — instead test file perms directly: the probe is rewritten in Step 2 once the directory model is in place. Run now — expect FAIL.

- [ ] **Step 2: Replace the probe with a perms-based check (no extra sudo)**

Replace `probe_codacy_roundtrip` with:
```bash
probe_codacy_roundtrip() {
  # /workspace/.codacy must be group-codacy, setgid, group-writable, so files
  # created by either user are editable by the other.
  local out; out="$(run_as_agent '
    stat -c "%G %A" /workspace/.codacy;
    touch /workspace/.codacy/agent-made.json && echo "agent-write-ok";
    stat -c "%G" /workspace/.codacy/agent-made.json
  ')"
  if echo "$out" | grep -q 'codacy' && echo "$out" | grep -q 'agent-write-ok' && echo "$out" | grep -q 's'; then
    pass "codacy roundtrip: shared setgid .codacy dir"
  else fail "codacy roundtrip: ($out)"; fi
}
```

- [ ] **Step 3: Prepare `/workspace/.codacy` in the entrypoint**

In `docker/entrypoint.sh`, immediately before the final `exec runuser ...` block, add:
```bash
# Shared scratch for the dual config mechanism: runner-run CLIs write here and
# the agent edits the files. setgid + group `codacy` + umask 002 keep both able
# to read/write each other's files.
mkdir -p /workspace/.codacy
chown runner:codacy /workspace/.codacy
chmod 2775 /workspace/.codacy
umask 002
```

- [ ] **Step 4: Build and run the probe — expect PASS**

```bash
docker build -f docker/Dockerfile -t codacy/autoconfig-test .
./docker/test-hardening.sh probe_codacy_roundtrip
```
Expected: PASS.
> Note: `/workspace` is a bind mount at runtime; the entrypoint sets perms on the mounted dir each run, so this holds for both the mounted (local) and cloned (server) cases.

- [ ] **Step 5: Commit**

```bash
git add docker/entrypoint.sh docker/test-hardening.sh
git commit -m "feat: shared setgid /workspace/.codacy for runner<->agent config handoff

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Server-pipeline — git token scrub + summary sanitize

In server mode, scrub the clone token from `.git/config` and sanitize the summary JSON before uploading it to the presigned URL, closing the upload exfil channel.

**Files:**
- Create: `docker/summary-sanitize.sh`
- Modify: `docker/server-pipeline.sh`
- Modify: `docker/test-hardening.sh` (add `probe_summary_sanitize`)

- [ ] **Step 1: Add the probe — expect FAIL**

Add to `docker/test-hardening.sh` and append to `ALL_PROBES`:
```bash
probe_summary_sanitize() {
  # The sanitizer must redact secret-shaped strings from a summary before upload.
  local out
  out="$(docker run --rm "${DUMMY_ENV[@]}" codacy/autoconfig-test bash -c '
    printf "%s\n" "{\"keyImprovements\":[\"leak sk-ant-api03-AAAABBBBCCCCDDDDEEEE and codacy tok 1234567890abcdef1234567890abcdef\"]}" > /tmp/s.json
    /usr/local/bin/summary-sanitize.sh /tmp/s.json
    cat /tmp/s.json' 2>&1)"
  if ! echo "$out" | grep -qE 'sk-ant-api03-AAAABBBB|1234567890abcdef1234567890abcdef' && echo "$out" | grep -q 'REDACTED'; then
    pass "summary sanitize: secrets redacted"
  else fail "summary sanitize: ($out)"; fi
}
```
Run it — expect FAIL.

- [ ] **Step 2: Write the sanitizer**

Create `docker/summary-sanitize.sh`:
```bash
#!/usr/bin/env bash
# Redacts secret-shaped tokens from a summary JSON in place, before it is
# uploaded. Defense-in-depth: even though the agent should hold no secret, the
# summary is agent-authored free text and must never carry a credential.
set -euo pipefail
FILE="$1"
[ -f "$FILE" ] || exit 0

# Anthropic keys (sk-ant-...), generic long hex/base64 tokens (>=32 chars),
# and bearer-style sk- tokens.
sed -E -i \
  -e 's/sk-ant-[A-Za-z0-9_-]{8,}/REDACTED/g' \
  -e 's/sk-[A-Za-z0-9_-]{16,}/REDACTED/g' \
  -e 's/[A-Fa-f0-9]{32,}/REDACTED/g' \
  -e 's/(ghp|gho|ghs|github_pat)_[A-Za-z0-9_]{16,}/REDACTED/g' \
  "$FILE"
```

- [ ] **Step 3: Wire it into the server pipeline + scrub the clone token**

In `docker/server-pipeline.sh`, after the `git clone` succeeds, add the remote-url scrub:
```bash
# Remove the token from the persisted remote URL so the agent cannot read it
# from .git/config.
git -C "${WORKSPACE}" remote set-url origin "https://${CLONE_HOST}/${CODACY_ORG_NAME}/${CODACY_REPO_NAME}.git" 2>/dev/null || true
```
And immediately before the `curl ... --upload-file "${SUMMARY_PATH}"` block, add:
```bash
echo "==> Sanitizing summary before upload"
/usr/local/bin/summary-sanitize.sh "${SUMMARY_PATH}"
```

- [ ] **Step 4: Add the sanitizer to the image**

In `docker/Dockerfile`, with the other `COPY docker/*.sh` lines:
```dockerfile
COPY docker/summary-sanitize.sh /usr/local/bin/summary-sanitize.sh
```
And include it in the `chmod +x` list.

- [ ] **Step 5: Build and run the probe — expect PASS**

```bash
docker build -f docker/Dockerfile -t codacy/autoconfig-test .
./docker/test-hardening.sh probe_summary_sanitize
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add docker/summary-sanitize.sh docker/server-pipeline.sh docker/Dockerfile docker/test-hardening.sh
git commit -m "feat: scrub git token from clone + sanitize summary before upload

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Firewall — proxy egress + DNS allowlist

Allow the proxy's egress to Anthropic and force DNS through a local resolver that answers only the allowlisted domains, dropping all other outbound port 53 (closes the DNS-exfil channel, CVE-2025-55284 class).

**Files:**
- Modify: `docker/Dockerfile` (install `dnsmasq`)
- Modify: `docker/init-firewall.sh`
- Modify: `docker/test-hardening.sh` (add `probe_dns_allowlist`)

- [ ] **Step 1: Add the probe — expect FAIL**

Add to `docker/test-hardening.sh` and append to `ALL_PROBES`:
```bash
probe_dns_allowlist() {
  # Allowlisted domain resolves; a non-allowlisted domain does not; the
  # existing egress sanity (example.com blocked, codacy reachable) still holds.
  local out; out="$(run_as_agent '
    getent hosts app.codacy.com >/dev/null 2>&1 && echo "codacy-resolves";
    getent hosts evil-not-allowed.example >/dev/null 2>&1 && echo "evil-resolves" || echo "evil-blocked";
  ')"
  if echo "$out" | grep -q 'codacy-resolves' && echo "$out" | grep -q 'evil-blocked'; then
    pass "dns allowlist: only allowlisted domains resolve"
  else fail "dns allowlist: ($out)"; fi
}
```
Run it — expect FAIL.

- [ ] **Step 2: Install dnsmasq in the Dockerfile**

In `docker/Dockerfile`, add `dnsmasq` to the `apt-get install` list (near `dnsutils`):
```dockerfile
    dnsutils \
    dnsmasq \
```

- [ ] **Step 3: Add DNS allowlist + proxy egress to the firewall**

In `docker/init-firewall.sh`, the domain allowlist loop already covers the Anthropic/Codacy hosts that the proxy needs (the proxy runs in-container and egresses to `api.anthropic.com`, which is already in the ipset) — no change needed for proxy egress beyond confirming `api.anthropic.com` is present (it is).

For DNS: after the allowlist `ipset` is built and before the default-deny `iptables -P OUTPUT DROP`, add a local resolver and lock DNS to it. Replace the existing protocol-level DNS lines:
```bash
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT  -p udp --sport 53 -j ACCEPT
```
with:
```bash
# DNS allowlist: run a local dnsmasq that resolves ONLY the allowlisted domains,
# and force all DNS through it. Drop any other outbound port 53 (closes DNS
# tunneling/exfil over UDP 53, the CVE-2025-55284 class).
DNS_UPSTREAM="$(grep -m1 '^nameserver' /etc/resolv.conf | awk '{print $2}')"
dnsmasq \
  --no-resolv --no-hosts --listen-address=127.0.0.1 --bind-interfaces \
  $(for d in api.anthropic.com statsig.anthropic.com api.codacy.com app.codacy.com app.dev.codacy.org app.staging.codacy.org; do echo --server=/$d/${DNS_UPSTREAM:-8.8.8.8}; done) \
  --address=/#/0.0.0.0
# Point the system resolver at dnsmasq.
echo "nameserver 127.0.0.1" > /etc/resolv.conf
# Allow DNS only to the local resolver; allow loopback; block all other 53.
iptables -A OUTPUT -o lo -p udp --dport 53 -d 127.0.0.1 -j ACCEPT
iptables -A INPUT  -i lo -p udp --sport 53 -s 127.0.0.1 -j ACCEPT
# dnsmasq's own upstream queries leave via the allowlisted IPs (ESTABLISHED) and
# the allowed-domains ipset; explicit upstream 53 to the resolver IP:
[ -n "${DNS_UPSTREAM:-}" ] && iptables -A OUTPUT -p udp --dport 53 -d "${DNS_UPSTREAM}" -j ACCEPT
```
> `--address=/#/0.0.0.0` makes every non-allowlisted name resolve to `0.0.0.0` (unroutable), so a non-allowlisted lookup cannot carry data to an external nameserver. The `--server=/domain/upstream` lines forward only the allowlisted names to the real upstream.
> Keep the existing `dig`-based ipset population loop as-is; it runs before `/etc/resolv.conf` is repointed, so it still resolves via the original upstream.

- [ ] **Step 4: Build and run the probe — expect PASS**

```bash
docker build -f docker/Dockerfile -t codacy/autoconfig-test .
./docker/test-hardening.sh probe_dns_allowlist
```
Expected: PASS. Also re-run the existing firewall sanity by checking entrypoint logs:
```bash
docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW --device /dev/kmsg:/dev/kmsg \
  -e CODACY_API_TOKEN=dummy -e ANTHROPIC_API_KEY=sk-dummy codacy/autoconfig-test true 2>&1 | grep -i firewall
```
Expected: "Firewall initialized" with no "FIREWALL ERROR".

- [ ] **Step 5: Commit**

```bash
git add docker/Dockerfile docker/init-firewall.sh docker/test-hardening.sh
git commit -m "feat: DNS allowlist via local dnsmasq, drop non-allowlisted outbound 53

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Drop Gemini

Gemini is not in use. Remove the pipeline branch, the env var, and the extension-install step. Keep the `gemini` binary in the image (cheap, harmless) but never invoke it.

**Files:**
- Modify: `docker/local-pipeline.sh`
- Modify: `docker/entrypoint.sh`
- Modify: `docker-compose.yml`, `.env.example`

- [ ] **Step 1: Require Anthropic, drop the Gemini branch in local-pipeline**

Replace the conditional in `docker/local-pipeline.sh` (the `if ANTHROPIC … elif GEMINI … else …` block) with:
```bash
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "Error: ANTHROPIC_API_KEY is not set." >&2
  exit 1
fi

echo "==> Running configure-codacy-cloud with Claude..."
claude -p "/configure-codacy-cloud" \
  --permission-mode dontAsk \
  --model haiku \
  --output-format stream-json \
  --verbose \
  --include-partial-messages \
  | jq --unbuffered -rj 'select(.type == "stream_event" and .event.delta.type? == "text_delta") | .event.delta.text'
```
> Note: claude reads `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` from the scrubbed agent env; the check above is on the *real* key, which is only present at the entrypoint/setup layer — so move this guard to the entrypoint instead. Concretely: in `docker/entrypoint.sh` step 4, if `ANTHROPIC_API_KEY` is unset, `echo` an error and `exit 1` rather than silently skipping the proxy. Then `local-pipeline.sh` can assume the proxy is up and simply run the claude command above without re-checking the key.

- [ ] **Step 2: Remove the Gemini extension install from the entrypoint**

In `docker/entrypoint.sh`, delete the block (if it still exists after Task 4's rewrite — it should already be gone, since the rewrite did not include it). Confirm there is no `gemini extensions install` line remaining:
```bash
grep -n gemini docker/entrypoint.sh || echo "no gemini references — good"
```
Expected: "no gemini references — good".

- [ ] **Step 3: Drop `GEMINI_API_KEY` from compose and the env example**

In `docker-compose.yml`, remove the `- GEMINI_API_KEY` line from `environment:`.
In `.env.example`, remove the `GEMINI_API_KEY=` line.

- [ ] **Step 4: Build and confirm the pipeline still wires up**

```bash
docker build -f docker/Dockerfile -t codacy/autoconfig-test .
./docker/test-hardening.sh probe_env_scrubbed
```
Expected: PASS (no `GEMINI_API_KEY` in agent env — it was never forwarded anyway, now also not declared).

- [ ] **Step 5: Commit**

```bash
git add docker/local-pipeline.sh docker/entrypoint.sh docker-compose.yml .env.example
git commit -m "chore: drop unused Gemini path (env var, pipeline branch, extension install)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: End-to-end smoke test (real keys)

Run the full local pipeline against a throwaway Codacy repo and assert the skill completes and the summary contains no secret. **Requires the user-provided fixtures.**

**Files:**
- Modify: `docker/test-hardening.sh` (add `probe_e2e`)

- [ ] **Step 1: Add the cli + e2e probes**

Add both to `docker/test-hardening.sh` (do NOT add to `ALL_PROBES` — they are opt-in via `./docker/test-hardening.sh cli` / `e2e` because they need real keys and network):
```bash
probe_cli() {
  # With a real token, the agent can drive the Codacy CLI through the shim
  # (proving runner-side credentials work) WITHOUT the token being in its env.
  : "${REAL_CODACY_TOKEN:?set REAL_CODACY_TOKEN}"
  local out
  out="$(docker run --rm "${CAPS[@]}" -e CODACY_API_TOKEN="$REAL_CODACY_TOKEN" -e ANTHROPIC_API_KEY=sk-dummy \
    codacy/autoconfig-test bash -c 'printenv CODACY_API_TOKEN; echo "---"; codacy --help >/dev/null 2>&1 && echo cli-ok' 2>&1)"
  if echo "$out" | grep -q 'cli-ok' && ! echo "$out" | grep -q "$REAL_CODACY_TOKEN"; then
    pass "cli: agent drives codacy via shim with no token in env"
  else fail "cli: ($out)"; fi
}


probe_e2e() {
  # Full local pipeline against a real throwaway Codacy repo. Requires:
  #   REAL_CODACY_TOKEN, REAL_ANTHROPIC_KEY, and a checkout at $E2E_REPO.
  : "${REAL_CODACY_TOKEN:?set REAL_CODACY_TOKEN}"; : "${REAL_ANTHROPIC_KEY:?set REAL_ANTHROPIC_KEY}"; : "${E2E_REPO:?set E2E_REPO to a local checkout already on Codacy}"
  local out
  out="$(docker run --rm "${CAPS[@]}" \
    -e CODACY_API_TOKEN="$REAL_CODACY_TOKEN" -e ANTHROPIC_API_KEY="$REAL_ANTHROPIC_KEY" \
    -v "$E2E_REPO":/workspace codacy/autoconfig-test local-pipeline.sh 2>&1)"
  echo "$out" | tail -20
  # Assert a summary was produced and contains no secret.
  local summary; summary="$(docker run --rm -v "$E2E_REPO":/workspace codacy/autoconfig-test \
    bash -c 'cat /workspace/.codacy/configure-codacy-cloud-summary.json 2>/dev/null')"
  if [[ -n "$summary" ]] && ! echo "$summary" | grep -qE "$REAL_CODACY_TOKEN|$REAL_ANTHROPIC_KEY|sk-ant-"; then
    pass "e2e: pipeline completed, summary clean of secrets"
  else fail "e2e: missing summary or secret present"; fi
}
```

- [ ] **Step 2: Run the e2e probe with the fixtures**

```bash
export REAL_CODACY_TOKEN=...        # Codacy Account API Token (account-scoped; use a throwaway account)
export REAL_ANTHROPIC_KEY=...       # dev/low-limit key
export E2E_REPO=/path/to/throwaway-checkout   # MUST be a git checkout with an `origin` remote that maps to a repo already on Codacy with >=1 finished analysis. The skill auto-detects provider/org/repo from the git remote; a plain folder or a non-Codacy repo makes it stop with "Could not detect repository from git remote".
./docker/test-hardening.sh cli
./docker/test-hardening.sh e2e
```
Expected: the skill runs (you will see streamed text), writes `/workspace/.codacy/configure-codacy-cloud-summary.json`, and the probe prints `PASS: e2e`. If claude is blocked on a legitimate command under `dontAsk`, note which command from the stream output and widen the Bash allowlist in `docker/claude-settings.json` (or fall back to `Bash(*)` per the spec), rebuild, and re-run.

- [ ] **Step 3: Run the full suite once more**

```bash
./docker/test-hardening.sh
```
Expected: all `ALL_PROBES` PASS (probes 1–10's worth).

- [ ] **Step 4: Commit**

```bash
git add docker/test-hardening.sh
git commit -m "test: add end-to-end smoke probe (real keys, asserts clean summary)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Documentation

Document the two-user model, the secret-handling contract, and the new test harness.

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update `CLAUDE.md`**

Add a section after "Container Architecture":
```markdown
## Security model (OD-78)

The agent runs least-privilege. Two OS users:
- **`runner` (1001)** — holds the Codacy credentials (`/home/runner/.codacy`, mode 700) and runs the Anthropic auth proxy (`anthropic-proxy.js`) that holds the real `ANTHROPIC_API_KEY`.
- **`agent` (1002)** — runs `claude -p`. Its environment contains **no real secret**: `ANTHROPIC_BASE_URL` points at the local proxy with a dummy token; `CODACY_API_TOKEN`/`GIT_TOKEN`/`GEMINI_API_KEY` are unset. It reaches the Codacy CLIs only through `/usr/local/bin/codacy{,-analysis}` shims that `sudo -u runner` the real binaries in `/opt/cli`.

The entrypoint runs as root: firewall → Codacy login as runner (token via env, never argv) → start proxy as runner → scrub env → `exec runuser -u agent`. Network egress is an iptables allowlist plus a dnsmasq DNS allowlist (only Anthropic + Codacy resolve). Claude runs on the Haiku model with `--permission-mode dontAsk` and a managed-settings lock.

Verify with `./docker/test-hardening.sh` (12 adversarial probes). Probes 1–10 need no live keys; the `e2e` probe needs a throwaway Codacy repo + tokens.
```

- [ ] **Step 2: Update `README.md`**

Under "What's inside", add a bullet:
```markdown
- Two-user privilege separation (`runner` holds secrets, `agent` runs Claude) + an Anthropic auth proxy, so a prompt-injected agent has no readable secret. See `docs/superpowers/specs/2026-06-11-harden-claude-agent-design.md` and run `./docker/test-hardening.sh` to verify.
```
And note the `GEMINI_API_KEY` removal: delete `GEMINI_API_KEY` from the documented `-e` flags and "Required env vars" lines (Anthropic is now required for the local pipeline).

- [ ] **Step 3: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: document two-user security model and verification harness

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Final verification

- [ ] Run the full suite: `./docker/test-hardening.sh` → all probes PASS.
- [ ] Run `./docker/test-hardening.sh e2e` with fixtures → PASS.
- [ ] Confirm no secret reaches the agent: `docker run --rm -e CODACY_API_TOKEN=x -e ANTHROPIC_API_KEY=y codacy/autoconfig-test bash -c 'printenv | grep -iE "codacy_api_token|anthropic_api_key|git_token"' ` prints nothing (or only the dummy).
- [ ] Open a PR from `worktree-od-78-harden-agent` referencing OD-78.

## Notes for the implementer

- **The slow loop is `docker build`.** Batch edits per task, build once, run that task's probe(s). Use `./docker/test-hardening.sh <probe>` (no rebuild) to iterate on a probe's assertion logic.
- **Root-start assumption:** the image starts as `USER root` and drops to `agent`. If the k8s deployment enforces `runAsNonRoot`, the drop-priv must instead start as `runner` and use a `runner ALL=(agent) NOPASSWD: ...` sudoers rule — flagged in the spec's risks. Confirm the AAM pod security context before shipping server mode.
- **Bash allowlist may need widening.** If the e2e probe shows the skill blocked on a legitimate command, capture it from the stream output and add its prefix to `docker/claude-settings.json`; fall back to `Bash(*)` only if prefix-matching proves unworkable (the OS layer still contains secrets either way).
