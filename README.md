# codacy/autoconfig

Runs an LLM agent against a repository to tune its Codacy Cloud configuration. Both CLIs are
installed — `claude` and `gemini` — and which one runs depends on the key you provide. Production
runs Gemini only; the Claude path exists but nothing in the cluster takes it.

The container treats the repository as untrusted: see
[docs/hardening-overview.md](docs/hardening-overview.md) for the two-user model, the Codacy CLI shim,
the Gemini admin policy, and the rest of the security design. The two agents are **not** protected
equally: Gemini runs under a root-owned admin policy, Claude runs with `Bash(*)` and `WebFetch(*)`
and no policy at all. That asymmetry is an accepted risk while the Claude path stays unused in
production — read [Claude is not hardened](docs/hardening-overview.md#claude-is-not-hardened) before
enabling `ANTHROPIC_API_KEY` anywhere.

## Running locally

**1. Create a `.env` file** in this directory:

```
CODACY_API_TOKEN=<your-codacy-api-token>
ANTHROPIC_API_KEY=<your-anthropic-api-key>
SOURCE_PATH=/absolute/path/to/your/repo
```

Set `ANTHROPIC_API_KEY` to run Claude, or `GEMINI_API_KEY` to run Gemini — at least one is required.
If both are set, Claude runs.

The repository at `SOURCE_PATH` must already be on Codacy Cloud with at least one finished analysis. The
container tunes the cloud configuration via Cloud reanalysis — it does not run local analysis, and it does
not import not-yet-on-Codacy repositories.

**2. Build the image** (first time, or after any script change):

```bash
docker compose build
```

**3. Run:**

```bash
docker compose run --rm codacy-ai
```

Docker Compose loads `.env` automatically — no shell exports needed. The result lands at:

```
$SOURCE_PATH/.codacy/configure-codacy-cloud-summary.json
```

### Overriding the model

Claude defaults to `claude-sonnet-4-6` and Gemini to `gemini-3-flash-preview`. Override with
`CLAUDE_MODEL` or `GEMINI_MODEL`, in `.env` or inline:

```bash
CLAUDE_MODEL=claude-opus-4-8 docker compose run --rm codacy-ai
```

### Running without the compose file

```bash
docker run --rm -it \
  -v codacy-tool-cache:/home/runner/.codacy \
  -v /path/to/your/repo:/workspace \
  --env-file .env \
  codacy/autoconfig local-pipeline.sh
```

| Flag                                      | Purpose                                                        |
|-------------------------------------------|----------------------------------------------------------------|
| `-v codacy-tool-cache:/home/runner/.codacy` | Persistent volume so downloaded tools survive between runs     |
| `-v /path/to/repo:/workspace`             | Mounts the repository as `/workspace`                          |
| `--env-file .env`                         | Loads all variables from the `.env` file                       |

## Pipelines: local, clone, server

The image ships three entrypoint scripts:

- `local-pipeline.sh` — for developers running the container against a mounted source folder. Used by
  `docker compose` and the `docker run` example above. Invokes `/configure-codacy-cloud` against `/workspace`.
- `clone-workspace.sh` — the production init container. Clones the repository with `GIT_TOKEN` into
  `/workspace`, sanitizes the checkout, and hands it to the `agent` user, then exits. The clone URL is
  built per provider (`CODACY_PROVIDER` of `gh`/`ghe` for GitHub, `gl`/`gle` for GitLab, `bb` for
  Bitbucket). A non-zero exit keeps the agent container from starting.
- `server-pipeline.sh` — for the Active Analysis Manager (AAM) in production. Expects `/workspace` to
  be populated already, invokes `/configure-codacy-cloud`, and uploads a JSON summary to a presigned
  S3 URL. It does **not** clone, and never sees `GIT_TOKEN`.

Both pipelines run the same skill, produce the same summary format, and capture the same run metadata
(`llm`, `model`, `tokensIn`, `tokensOut`, `durationMs`, `costUsd`, `sessionId`).

### Testing server-pipeline.sh locally

Two steps, sharing a `/workspace` volume, mirroring the init-container split in production:

```bash
docker volume create autoconfig-ws

docker run --rm \
  -v autoconfig-ws:/workspace \
  -e GIT_TOKEN=<token> \
  -e CODACY_PROVIDER=gh \
  -e CODACY_ORG_NAME=your-org \
  -e CODACY_REPO_NAME=your-repo \
  codacy/autoconfig clone-workspace.sh

docker run --rm -it \
  -v codacy-tool-cache:/home/runner/.codacy \
  -v autoconfig-ws:/workspace \
  --env-file .env \
  -e CODACY_PROVIDER=gh \
  -e CODACY_ORG_NAME=your-org \
  -e CODACY_REPO_NAME=your-repo \
  -e RESULT_UPLOAD_URL=https://httpbin.org/put \
  codacy/autoconfig server-pipeline.sh
```

Pass the script as the command, not as `--entrypoint`: the image entrypoint is what stages the
Codacy token and drops privilege to the `agent` user, and skipping it skips both. `clone-workspace.sh`
is the single exception: the entrypoint execs it as root and untouched, because the clone needs
`GIT_TOKEN`. `server-pipeline.sh` exits 1 if `/workspace` is empty.

`httpbin.org/put` accepts any PUT and is useful for smoke-testing the upload step.

To capture the summary on your host instead, run a tiny HTTP sink in another terminal:

```bash
python3 -c "
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_PUT(self):
        n = int(self.headers.get('Content-Length', 0))
        open('summary.json', 'wb').write(self.rfile.read(n))
        self.send_response(200); self.end_headers()
http.server.HTTPServer(('0.0.0.0', 8080), H).serve_forever()
"
```

Then set `RESULT_UPLOAD_URL=http://host.docker.internal:8080/upload`.

Required env vars for the server pipeline: `CODACY_API_TOKEN`, `GIT_TOKEN`, `CODACY_PROVIDER`,
`CODACY_ORG_NAME`, `CODACY_REPO_NAME`, `RESULT_UPLOAD_URL`, plus `ANTHROPIC_API_KEY` or
`GEMINI_API_KEY` (at least one). The scripts fail fast if any are missing.

`local-pipeline.sh` needs only `CODACY_API_TOKEN` and one LLM key: it runs against the folder you
mounted, so it neither clones nor sanitizes it.

## What's inside

- `codacy` — Codacy Cloud CLI, reachable only through a `sudo` shim that runs it as `runner`
- `codacy-analysis` — Codacy Analysis CLI (used by the skill only for config-file operations)
- `claude` / `gemini` — AI assistants, both pinned to a fixed version
- The `configure-codacy-cloud` skill and its siblings, pre-baked from `codacy/codacy-skills`
- `git`, `jq`, `curl`, `unzip`, `ripgrep`, `sudo` on top of `node:20-bookworm-slim`

Egress is not restricted inside the container. Local runs are trusted; in production egress is enforced by
k8s NetworkPolicy at the cluster level. See
[docs/hardening-overview.md](docs/hardening-overview.md) for what the container does and does not
protect against.
