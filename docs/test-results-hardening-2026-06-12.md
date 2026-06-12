# Hardening test results (OD-78) — 2026-06-12

Validation of the least-privilege hardening (two-user split, Anthropic auth proxy,
env scrub, sudo CLI shim, DNS allowlist, tightened tool policy). Run against the
built image `codacy/autoconfig-test` on Docker 29.2.0 (macOS, arm64).

Harness: `docker/test-hardening.sh`. Live-key fixtures: a Codacy **Account API Token**
+ an Anthropic API key (from `.env`), and the Codacy-tracked checkout
`troubleshoot-codacy-dev/access-test`.

## 1. Keyless adversarial probe suite — 12/12 PASS

Each probe runs **as the hijacked agent would** (the entrypoint drops privilege
before exec'ing the probe). No live keys needed.

| # | Probe | Asserts | Result |
|---|-------|---------|--------|
| 1 | smoke | final command runs as `agent` (uid 1002), not root/node | PASS |
| 2 | distinct_uids | `agent`=1002, `runner`=1001 (distinct, non-root) | PASS |
| 3 | shim | `codacy` on PATH is the `sudo→runner` shim | PASS |
| 4 | creds_unreadable | agent cannot read the runner token file / creds dir | PASS |
| 5 | env_scrubbed | no `CODACY_API_TOKEN`/`GIT_TOKEN`/`GEMINI_API_KEY` in agent env; `ANTHROPIC_BASE_URL` points at the local proxy | PASS |
| 6 | no_cmdline_leak | no token in any `/proc/*/cmdline` | PASS |
| 7 | proc_env | agent cannot read `runner`/proxy `/proc/<pid>/environ` (different uid) | PASS |
| 8 | direct_anthropic | the dummy token the agent holds is rejected by Anthropic (401) | PASS |
| 9 | tool_policy | no `WebFetch`/`Glob`/`Grep`; secret-path denies present; managed-settings lock present | PASS |
| 10 | codacy_roundtrip | `/workspace/.codacy` is shared setgid group `codacy` (runner↔agent handoff) | PASS |
| 11 | summary_sanitize | planted fake tokens redacted from a summary before upload | PASS |
| 12 | dns_allowlist | allowlisted domain resolves to a real IP; non-allowlisted resolves to `0.0.0.0` (sinkholed); firewall sanity OK | PASS |

Sample: `dns allowlist: codacy=65.9.62.97, evil=0.0.0.0 (sinkholed)`.

## 2. Credential path (live token, no reanalysis)

`codacy repo --output json` run **as the agent** through the shim returned real
repository JSON (`gh / troubleshoot-codacy-dev / access-test`), while:

- the agent's own `CODACY_API_TOKEN` env var was **empty** (scrubbed), and
- the staged token file `/run/codacy/codacy.env` was **unreadable** by the agent.

Confirms the runner-side launcher supplies the token to the CLI without ever
exposing it to the agent.

## 3. End-to-end pipeline (live keys, real Codacy reanalysis)

Ran `local-pipeline.sh` against `access-test` with the firewall **enabled** (the
realistic configuration). Three iterations — each surfaced one real defect, fixed,
until a full clean run:

### Run 1 — `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` ⇒ bubblewrap required
Claude refused to start: *"bubblewrap is required for subprocess env scrubbing and
isolation."* No API tokens spent.
**Fix:** removed the env var. It was redundant — the entrypoint's `env -i` already
hands the agent a clean, secret-free environment, so there is nothing for
subprocess-scrub to protect, and we deliberately do not rely on bubblewrap in
unprivileged Docker.

### Run 2 — `dontAsk` + Bash prefix-allowlist ⇒ skill blocked
Claude started (proving **the auth proxy injected the real key** and the skill ran
through the shim), captured the baseline (27 issues / 1,646 patterns / 7 tools),
generated + merged the auto config, and **imported 3,276 patterns** — then stalled:
*"I'm encountering permission restrictions on certain bash operations."* The tight
Bash prefix-allowlist denied the skill's helper commands (`sed`/`cat`/scripts) under
`dontAsk`.
**Fix:** fell back to `Bash(*)` per the plan, keeping the deny list
(`curl`/`wget`/`ssh`/`dig`/`nslookup`/`host`/`ping`), the scoped `Read`/`Write`/`Edit`,
and the managed-settings lock. The OS layer is the real boundary — the agent still
holds no readable secret regardless of Bash breadth.

### Run 3 — `Bash(*)` ⇒ full success ✅
The skill completed the entire workflow on **Haiku** through the hardened stack:
verify prerequisites → baseline → import → reanalysis (19 → 29 issues) → refine
(disabled redundant Biome) → handled a **409 coding-standard conflict** gracefully
(`security_detect-object-injection` enforced by the "avc" standard, recorded in
`conflicts[]`) → wrote the summary.

Final summary `/workspace/.codacy/configure-codacy-cloud-summary.json` (3.3 KB,
valid JSON, keys: `summary`, `toolChanges`, `patternChanges`, `conflicts`,
`recommendedPathsToIgnore`, `keyImprovements`). **Secret scan: CLEAN** — no Codacy
token, Anthropic key, `sk-ant-`, or dummy token present.

Skill's own before/after (the repo's config, not a hardening metric):

| Metric | Before | After |
|--------|-------:|------:|
| Issues | 19 | 29 (more security/error-prone, less noise) |
| Security | 12 | 19 |
| Error-Prone | 2 | 8 |
| Unused Code | 5 | 0 |
| Enabled tools | 10 | 9 (Biome disabled) |

## 4. Hardening verified end-to-end

Across the runs, every defense was exercised by a real workload:

- **Auth proxy** — claude reached Anthropic only via `127.0.0.1:8118` with a dummy
  token; the proxy injected the real key (Run 3 produced model output).
- **Two-user + shim + token file** — `codacy`/`codacy-analysis` ran as `runner`
  and authenticated, with no token in the agent's env or argv.
- **Env scrub / drop-priv** — agent ran as uid 1002 with no real secret.
- **Firewall + DNS allowlist** — pipeline reached `api.codacy.com` /
  `api.anthropic.com`; non-allowlisted DNS sinkholed.
- **`dontAsk` + managed settings** — enforced (it actively denied in Run 2);
  policy is a repo-uncloseable floor.
- **Summary sanitize** — output uploaded clean of secrets.

## 5. Defects found and fixed during testing

| Found by | Defect | Fix |
|----------|--------|-----|
| Task 2 build | npm bin is a relative symlink; moving to `/opt/cli` would break it | Rename `*-real` in the same dir; shim at the original name |
| Task 9 e2e | dnsmasq forward failed post-default-deny (Docker resolver couldn't egress) | Forward to a real resolver, root-only egress; `--ipset` adds resolved IPs (no CDN race) |
| Credential check | `codacy login` does **not** persist the token from the env var | Stage the token in a runner-only file; runner-side launcher loads it (CLI reads `CODACY_API_TOKEN` at runtime) |
| e2e Run 1 | `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` requires bubblewrap | Removed (redundant given `env -i`) |
| e2e Run 2 | Bash prefix-allowlist too tight for the skill under `dontAsk` | `Bash(*)` + deny list (OS layer is the boundary) |

## 6. Notes / follow-ups

- **Bash policy is `Bash(*)`** (not a prefix allowlist) by design — documented in the
  spec/overview. Security rests on the OS layer, not Claude's permission policy.
- `CODACY_API_TOKEN` is an **Account API Token** (account-scoped); it cannot be
  narrowed, which is why OS-level unreadability is the load-bearing control. Open
  follow-up: ask Codacy whether a narrower token can drive cloud config.
- The reanalysis step consumes Anthropic tokens; a token-exhausted run stops
  mid-skill but leaks nothing (verified).
