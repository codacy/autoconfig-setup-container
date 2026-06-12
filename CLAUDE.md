# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Docker image that runs an AI-powered Codacy configuration skill. Claude Code (the `claude` CLI) is the runtime; the container provides a least-privilege sandbox with the right tools and an outbound firewall. The actual configuration logic lives in the **`configure-codacy-cloud` skill**, pulled from [`codacy/codacy-skills`](https://github.com/codacy/codacy-skills) at image build time and baked into `/home/agent/.claude/commands/`.

The container **does not run local static analysis**. It tunes a repository's Codacy Cloud configuration via Cloud reanalysis only.

## Build and Run

```bash
# Build image
docker compose build

# Run against the current directory (set SOURCE_PATH to point elsewhere)
docker compose run --rm codacy-ai
```

Required env vars in `.env` (copy from `.env.example`): `CODACY_API_TOKEN` + `ANTHROPIC_API_KEY`. `CODACY_API_TOKEN` is a Codacy **Account API Token** (account-scoped — there is no repo-scoped token that can drive cloud config). The mounted `/workspace` must be a git checkout whose `origin` maps to a repo already on Codacy with a finished analysis.

## Two Pipelines

**`local-pipeline.sh`** (default `CMD`): for developers. Mounts `/workspace` from host. Runs `/configure-codacy-cloud` via Claude (Haiku, `--permission-mode dontAsk`).

**`server-pipeline.sh`**: for the Active Analysis Manager (AAM) in production (k8s). Validates required env vars, clones the repo via `GIT_TOKEN` (then scrubs the token from the remote URL), runs `/configure-codacy-cloud`, sanitizes the summary, and PUT-uploads a JSONL summary to `RESULT_UPLOAD_URL` (presigned S3). Exit code 2 = upload failure; non-zero from skill = skill failure.

Additional vars required for server pipeline: `GIT_TOKEN`, `CODACY_PROVIDER` (`gh`/`ghe`/`gl`/`gle`/`bb`), `CODACY_ORG_NAME`, `CODACY_REPO_NAME`, `RESULT_UPLOAD_URL`.

To test server pipeline locally (firewall blocks git providers — skip it with `RUNNING_IN_K8S=true`):
```bash
docker run --rm -it \
  -v codacy-tool-cache:/home/runner/.codacy \
  -e RUNNING_IN_K8S=true \
  -e CODACY_API_TOKEN -e ANTHROPIC_API_KEY -e GIT_TOKEN \
  -e CODACY_PROVIDER=gh -e CODACY_ORG_NAME=your-org -e CODACY_REPO_NAME=your-repo \
  -e RESULT_UPLOAD_URL=https://httpbin.org/put \
  --entrypoint /usr/local/bin/server-pipeline.sh \
  codacy/autoconfig
```

## Security model (OD-78)

The agent runs least-privilege so a prompt injection from the untrusted `/workspace` cannot steal a secret. Two OS users:

- **`runner` (uid 1001)** — holds the Codacy credentials (`/home/runner/.codacy`, mode 700) and runs the Anthropic auth proxy (`anthropic-proxy.js`) that holds the real `ANTHROPIC_API_KEY`.
- **`agent` (uid 1002)** — runs `claude -p`. Its environment contains **no real secret**: `ANTHROPIC_BASE_URL` points at the local proxy with a dummy token; `CODACY_API_TOKEN`/`GIT_TOKEN`/`GEMINI_API_KEY` are unset. It reaches the Codacy CLIs only through `/usr/local/bin/codacy{,-analysis}` shims that `sudo -u runner` the real binaries (renamed `*-real`).

The entrypoint runs as root: firewall → Codacy login as runner (token via env, never argv) → start proxy as runner → scrub env → `exec runuser -u agent`. Network egress is an iptables IP allowlist **plus** a dnsmasq DNS allowlist (only Anthropic + Codacy resolve; everything else is sinkholed to `0.0.0.0`, and only root may reach the upstream resolver). Claude runs on Haiku with `--permission-mode dontAsk` and a managed-settings lock (`/etc/claude-code/managed-settings.json`).

Verify with `./docker/test-hardening.sh` (adversarial probes). Probes 1–12 need no live keys; the opt-in `cli` / `e2e` probes need a throwaway Codacy account token + a Codacy-tracked git checkout. Design: `docs/superpowers/specs/2026-06-11-harden-claude-agent-design.md`; overview: `docs/hardening-overview.md`.

## Container Architecture

**Entrypoint** (`entrypoint.sh`): firewall init (skipped when `RUNNING_IN_K8S=true`) → Codacy login as `runner` → start Anthropic proxy as `runner` → prepare shared setgid `/workspace/.codacy` → scrub env and `exec runuser -u agent -- … "$@"`.

**Firewall** (`init-firewall.sh`): iptables + ipset IP allowlist (`api.anthropic.com`, `statsig.anthropic.com`, `generativelanguage.googleapis.com`, `oauth2.googleapis.com`, `api.codacy.com`, `app.codacy.com`, `app.dev.codacy.org`, `app.staging.codacy.org`) + a local dnsmasq DNS allowlist for the same domains. Logs blocked connections via `/dev/kmsg`. In k8s, egress is handled by NetworkPolicy instead (firewall skipped).

**Skills** baked into `/home/agent/.claude/commands/`: `configure-codacy-cloud`, `configure-codacy`, `codacy-analysis-cli`, `codacy-cloud-cli`. The Dockerfile uses `ADD https://api.github.com/.../refs/heads/master` as a cache-buster so `docker build` always fetches the latest skills without `--no-cache`.

**Installed CLIs** (npm globals): `claude` (`@anthropic-ai/claude-code`), `gemini` (present but unused), `codacy` (`@codacy/codacy-cloud-cli`), `codacy-analysis` (`@codacy/analysis-cli`). Claude permissions in `claude-settings.json` are tightened (no `WebFetch`/`Glob`/`Grep`; `Read`/`Write`/`Edit` scoped to `/workspace`; secret-path + network-binary denies; Bash prefix allowlist).

**Runtimes** available for tools: Java (default-jdk-headless), Python 3, Ruby, Go 1.26, shellcheck.

**Volume** `codacy-tool-cache` → `/home/runner/.codacy`: persists downloaded tool binaries and Trivy DB across container runs.

## Updating Skills

Skills are fetched from `codacy-skills` master at build time. To pick up skill changes, rebuild:
```bash
docker compose build
```
The `ADD` cache-buster in the Dockerfile invalidates the layer when `codacy-skills` master moves.
