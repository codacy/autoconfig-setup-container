# Harden the Claude agent in autoconfig-container (OD-78)

- **Status:** Design — pending user review (revised after prior-art research)
- **Linear:** [OD-78](https://linear.app/codacy/issue/OD-78/autoconfig-containerinvestigate-tighten-security-for-claude-agent)
- **Date:** 2026-06-11
- **Approach chosen:** Hybrid — deterministic OS boundary (iptables firewall + two-user) **plus** first-party Claude Code hardening layered on top.

## Problem

The container runs `claude -p "/configure-codacy-cloud"` against `/workspace`, which is **untrusted customer code** (mounted in local mode, `git clone`d in server mode). The skill inspects Codacy issue data — **code excerpts, issue messages, and file paths from the repo** (`codacy issues -p <patternId> -o json`). That is a viable **indirect prompt-injection channel**: crafted repo content surfaces in the agent's context and can hijack it.

Today the agent has `Bash(*)` + broad tools and **all secrets in its environment** (`CODACY_API_TOKEN`, `ANTHROPIC_API_KEY`, optional `GEMINI_API_KEY`, server-mode `GIT_TOKEN`). A hijacked agent reads them trivially (`env`, `cat ~/.codacy/credentials`) and exfiltrates through channels the egress allowlist does **not** stop: writing a secret into an allowed SaaS field and reading it back, the summary-JSON upload (server mode, firewall skipped in k8s), or **DNS** (UDP 53). Highest-value loss: `ANTHROPIC_API_KEY` and server-mode `GIT_TOKEN`.

## Why this is real (validated by research)

- **Lethal trifecta** (Willison, [link](https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/)): private data + untrusted content + exfil channel ⇒ structurally vulnerable. We cannot remove untrusted content (it is a code tool), so we **must** remove readable secrets.
- **Permission/prompt policy is containment, not a boundary.** OWASP LLM01/02, NIST, Oso, Willison all converge: real control is the OS/network layer. ([OWASP LLM01](https://genai.owasp.org/llmrisk/llm01-prompt-injection/), [Oso](https://www.osohq.com/learn/why-prompt-based-safety-is-not-enough))
- **Egress allowlist insufficient alone:** exfil via allowed SaaS fields and via DNS. **DNS exfil is a live Claude Code CVE — [CVE-2025-55284](https://embracethered.com/blog/posts/2025/claude-code-exfiltration-via-dns-requests/)** (`.env` encoded into DNS subdomain labels). So DNS hardening ships in this work, not as a maybe.

## Goal / non-goals

**Goal:** after a successful hijack, the agent has **no readable secret** to steal, enforced at the OS layer; first-party Claude Code features add cheap defense-in-depth but are **not** the load-bearing control.

**Non-goals:** preventing legitimate-scope Codacy misconfiguration; kernel/container escape; reworking the `configure-codacy-cloud` skill (separate repo).

## Prior art we adopt instead of hand-rolling

Research found Claude Code ships primitives that replace parts of the original hand-rolled plan. We **use the cheap ones**, but do **not** trust them as the sole boundary — Anthropic's own docs note the sandbox is **weakened inside unprivileged Docker** (`enableWeakerNestedSandbox` "considerably weakens security"), covers **Bash only**, and several "setting ignored" bugs exist. Hence hybrid.

| First-party feature | Use | Source |
|---|---|---|
| `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` | strip Anthropic/cloud creds from Bash subprocess env | docs.claude.com/en/env-vars |
| Native LLM gateway (`ANTHROPIC_BASE_URL` + dummy `ANTHROPIC_AUTH_TOKEN`) | the supported way to keep the real key out of the agent — our proxy points here | docs.claude.com/en/llm-gateway |
| Managed settings (`/etc/claude-code/managed-settings.json`) + `allowManagedPermissionRulesOnly`, `disableBypassPermissionsMode`, `failIfUnavailable: true` | policy the repo/agent cannot widen | docs.claude.com/en/permissions |
| `--permission-mode dontAsk` | auto-deny anything not allowlisted (correct headless mode) | docs.claude.com/en/permissions |
| `Read`/`Edit` deny rules for secret paths | env-scrub alone leaves `/proc/self/environ` readable by the `Read` tool | docs.claude.com/en/permissions |
| [Trail of Bits `claude-code-devcontainer`](https://github.com/trailofbits/claude-code-devcontainer) | reference patterns for untrusted-code hardening | — |

**Rejected:** `@anthropic-ai/sandbox-runtime` as the network boundary — weakened in our unprivileged Docker; the existing iptables firewall (works with `NET_ADMIN`) is the stronger deterministic net control here. Self-hosted LiteLLM as the gateway — recent supply-chain compromise; a ~40-line first-party-compatible proxy is smaller attack surface (revisit Cloudflare AI Gateway / LiteLLM-pinned if a managed gateway is preferred later).

## Architecture (hybrid)

Deterministic OS boundary — two real UIDs in one container:

| User | UID | Holds | Runs |
|---|---|---|---|
| `runner` | 1001 | Codacy credentials file; real `ANTHROPIC_API_KEY` (inside the proxy process) | the auth proxy; the real `codacy`/`codacy-analysis` (via sudo) |
| `agent` | 1002 | nothing sensitive | `claude`, `jq`, shell, repo edits |

Distinct UIDs matter: a different unprivileged UID **cannot** read the other's `/proc/<pid>/environ` or `/cmdline` without `CAP_SYS_PTRACE` (kernel proc(5) rule) — so the two-user split genuinely blocks `/proc` snooping, which env-scrub + Read-deny alone do not fully guarantee.

```
   /workspace      agent (uid 1002)            runner (uid 1001)
  (untrusted) ──▶  claude -p                    anthropic-proxy ──▶ api.anthropic.com
                   ANTHROPIC_BASE_URL=127.0.0.1 (real key here)     (real key injected)
                   dummy token, env-scrubbed
                   codacy shim ──sudo──▶         codacy/codacy-analysis ──▶ api.codacy.com
                   (can't read creds/proc)       (reads ~runner/.codacy/credentials)
```

### Components

1. **Setup + drop-priv (entrypoint / pipeline), as `runner`/root before the agent:**
   - Authenticate Codacy **without token in argv** (`/proc/<pid>/cmdline` is world-readable; argv secrets = CWE-214). Use `CODACY_API_TOKEN=… codacy login` (env) or stdin — **not** `codacy login --token <tok>`. If only `--token` exists, write the credentials file directly as `runner`.
   - Start the anthropic proxy as `runner` (real key in its env only).
   - Server mode: `git clone` with the token, then `git remote set-url origin <tokenless>` (or drop remote) so the token does not persist in `.git/config`.
   - Scrub the agent env: `unset CODACY_API_TOKEN GIT_TOKEN GEMINI_API_KEY`; set `ANTHROPIC_BASE_URL=http://127.0.0.1:<PORT>`, dummy `ANTHROPIC_AUTH_TOKEN`, and `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` per docs.
   - `exec` claude as `agent` (`runuser`/`setpriv`/`sudo -u`; pick one that passes the scrubbed env and a TTY for `-it` local runs), with `--permission-mode dontAsk`.

2. **Anthropic auth proxy** (~40 lines, Node already in image): listens `127.0.0.1:<PORT>`, forwards to `https://api.anthropic.com`, **replaces** the auth header with the real key from its runner-owned env, ignores the dummy. Agent cannot read its env (distinct UID). Firewall allows proxy→Anthropic. *(Gemini path: scrub `GEMINI_API_KEY` and treat Gemini as not-hardened/document-out, or give it the same proxy — decided at plan time. Server mode is Claude-only.)*

3. **Two-user + sudo CLI wrappers (Dockerfile):** users `runner`(1001)/`agent`(1002) + shared group `codacy`. Real CLIs moved to `/opt/cli/`; `PATH` shims `exec sudo -n -u runner /opt/cli/<cli> "$@"`. Sudoers: `agent ALL=(runner) NOPASSWD: /opt/cli/codacy, /opt/cli/codacy-analysis`. Keep root NOPASSWD for `init-firewall.sh` (now run in setup). Credentials at `/home/runner/.codacy` (700). Tool-cache volume moves `/home/node/.codacy` → `/home/runner/.codacy`.

4. **Cross-user `.codacy/` sharing:** CLIs (as `runner`) write `/workspace/.codacy/*.json`; agent must read **and edit** `auto.config.json`. Make `/workspace/.codacy` group `codacy`, `g+rwxs` (setgid), umask `002` for both users. Validate the round-trip in tests.

5. **Tool policy + managed settings:**
   - **Managed** `/etc/claude-code/managed-settings.json` (repo cannot widen): `allowManagedPermissionRulesOnly: true`, `disableBypassPermissionsMode: "disable"`, `failIfUnavailable: true`.
   - Permissions: **remove** `WebFetch`, `Glob`, `Grep`; scope `Read`/`Write`/`Edit` to `/workspace/**`; add **deny** rules for secret paths (`/home/runner/**`, `/proc/*/environ`, `~/.codacy/**`). `Bash`: allow needed prefixes (`Bash(codacy:*)`, `Bash(codacy-analysis:*)`, `Bash(jq:*)`, `Bash(mkdir:*)`, `Bash(rm:*)`, `Bash(cd:*)`). Research confirms Claude matches each segment of compound commands independently (pipes/`&&`/redirects are split), but **arg-restriction allowlists are documented-fragile** — so the OS layer remains the boundary; if prefix matching breaks the skill in `dontAsk`, fall back to broader `Bash` knowing secrets are already unreadable.

6. **DNS hardening (in-scope):** route DNS through a local resolver (dnsmasq/unbound) answering only allowlisted domains; drop other outbound UDP 53. Closes CVE-2025-55284-class exfil and the semantic-transformation gap the IP allowlist cannot.

## Files touched

`docker/Dockerfile` (users/group, CLI move + shims, sudoers, creds path, proxy + managed-settings copy), `docker/entrypoint.sh` (pre-auth, proxy, env scrub, drop-priv, `dontAsk`), `docker/local-pipeline.sh` + `docker/server-pipeline.sh` (new model; clone token scrub; summary sanitize before upload), `docker/init-firewall.sh` (proxy egress; DNS resolver rules), `docker/claude-settings.json` (tightened), **new** `docker/managed-settings.json`, **new** `docker/anthropic-proxy.js`, **new** `docker/test-hardening.sh`, `README.md` + `CLAUDE.md` (two-user model, env contract).

## Verification harness (built first, run every loop)

`docker/test-hardening.sh` builds the image and runs **adversarial probes as `agent`**, non-zero on any failure. Probes 1–11 need no live keys; probe 12 uses the throwaway fixtures.

1. **Env scrubbed** — `printenv` has no `CODACY_API_TOKEN`/`GIT_TOKEN`/`GEMINI_API_KEY`; `ANTHROPIC_API_KEY` absent or dummy.
2. **Credentials unreadable** — `cat /home/runner/.codacy/credentials` → denied; no copy in `/home/agent`.
3. **No `/proc` env leak** — reading `/proc/<runner-pid>/environ` and proxy pid → denied.
4. **No cmdline leak** — no token substring in any `/proc/*/cmdline`.
5. **CLI works via shim** — `codacy repo --output json` as `agent` succeeds without exposing the token.
6. **Direct Anthropic call fails for agent** — `curl api.anthropic.com` with agent env → 401; claude via proxy works.
7. **Proxy injects real key** — request via proxy authenticates; dummy token does not directly.
8. **`.codacy` round-trip** — runner-written `auto.config.json` editable by agent and readable back by a runner-run CLI.
9. **Tool policy** — settings have no `WebFetch`/`Glob`/`Grep`; `Read`/`Write`/`Edit` scoped; secret-path deny rules present; managed-settings flags set.
10. **Summary sanitizer** — planted fake token stripped/flagged before mocked upload.
11. **Firewall + DNS** — `example.com` blocked, `app.codacy.com` reachable, proxy→Anthropic allowed; lookup of a non-allowlisted domain refused, outbound 53 to non-resolver dropped.
12. **E2E smoke (real keys)** — `local-pipeline.sh` against a throwaway Codacy repo completes, writes a summary, and the summary contains **no** secret.

### Fixtures the user provides
A throwaway Codacy repo already on Codacy with ≥1 finished analysis; a **repo-scoped** `CODACY_API_TOKEN`; an `ANTHROPIC_API_KEY` (dev/low-limit fine); for server-mode tests a `GIT_TOKEN` + provider/org/repo and a local PUT sink for `RESULT_UPLOAD_URL`. Passed via `--env-file`/`-e` at test time, never committed.

## Risks / open items

- **Bash allowlist vs compound commands** — may fall back to broad `Bash` + OS isolation (acceptable; OS is the boundary).
- **`codacy login` token-input method** — must avoid argv; confirm env/stdin or write creds file directly.
- **Drop-priv mechanism** — `runuser`/`setpriv`/`sudo -u`; must pass scrubbed env + TTY for local `-it`.
- **Built-in sandbox in Docker is weakened** — deliberately not relied on for the network boundary; iptables + two-user are.
- **Gemini path** — hardened or documented-out (plan-time decision).
- **k8s parity** — server mode skips the in-container firewall; two-user + proxy are not firewall-dependent and still hold; confirm NetworkPolicy allows proxy→Anthropic and consider DNS policy at cluster level.

## Rollout

1. Build the verification harness + hybrid core (two-user, wrappers, proxy, env scrub, managed-settings + `dontAsk`, tool policy).
2. Iterate build→probe until 1–11 pass; then probe 12 with real fixtures.
3. DNS hardening in the same PR (promoted from P2).
4. Update README/CLAUDE.md.
