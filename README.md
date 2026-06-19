# codacy/autoconfig

## Running locally

**1. Create a `.env` file** in this directory:

```
CODACY_API_TOKEN=<your-codacy-api-token>
ANTHROPIC_API_KEY=<your-anthropic-api-key>
SOURCE_PATH=/absolute/path/to/your/repo
```

`GEMINI_API_KEY` is optional — set it instead of (or alongside) `ANTHROPIC_API_KEY` to use Gemini.

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

The default model is `claude-sonnet-4-6`. To use a different one, set `CLAUDE_MODEL` in `.env` or inline:

```bash
CLAUDE_MODEL=claude-opus-4-8 docker compose run --rm codacy-ai
```

### Running without the compose file

```bash
docker run --rm -it \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  --device /dev/kmsg:/dev/kmsg \
  -v codacy-tool-cache:/home/node/.codacy \
  -v /path/to/your/repo:/workspace \
  --env-file .env \
  codacy/autoconfig local-pipeline.sh
```

| Flag                                      | Purpose                                                        |
|-------------------------------------------|----------------------------------------------------------------|
| `--cap-add=NET_ADMIN --cap-add=NET_RAW`   | Required to enforce the outbound firewall inside the container |
| `--device /dev/kmsg:/dev/kmsg`            | Kernel device needed by the firewall block-log stream          |
| `-v codacy-tool-cache:/home/node/.codacy` | Persistent volume so downloaded tools survive between runs     |
| `-v /path/to/repo:/workspace`             | Mounts the repository as `/workspace`                          |
| `--env-file .env`                         | Loads all variables from the `.env` file                       |

## Two pipelines, local and server

The image ships two entrypoint scripts:

- `local-pipeline.sh` — for developers running the container against a mounted source folder. Used by
  `docker compose` and the `docker run` example above. Invokes `/configure-codacy-cloud` against `/workspace`.
- `server-pipeline.sh` — for the Active Analysis Manager (AAM) in production. Clones the repository via
  `GIT_TOKEN`, invokes `/configure-codacy-cloud`, and uploads a JSON summary to a presigned S3 URL. The
  clone URL is built per provider (`CODACY_PROVIDER` of `gh`/`ghe` for GitHub, `gl`/`gle` for GitLab,
  `bb` for Bitbucket).

Both scripts run the same skill, produce the same summary format, and capture the same run metadata
(`llm`, `model`, `tokensIn`, `tokensOut`, `durationMs`, `costUsd`, `sessionId`).

### Testing server-pipeline.sh locally

The local firewall does not allow git provider hosts, so set `RUNNING_IN_K8S=true` to skip it:

```bash
docker run --rm -it \
  -v codacy-tool-cache:/home/node/.codacy \
  --env-file .env \
  -e RUNNING_IN_K8S=true \
  -e GIT_TOKEN=<token> \
  -e CODACY_PROVIDER=gh \
  -e CODACY_ORG_NAME=your-org \
  -e CODACY_REPO_NAME=your-repo \
  -e RESULT_UPLOAD_URL=https://httpbin.org/put \
  --entrypoint /usr/local/bin/server-pipeline.sh \
  codacy/autoconfig
```

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

Required env vars for the server pipeline: `CODACY_API_TOKEN`, `ANTHROPIC_API_KEY`, `GIT_TOKEN`,
`CODACY_PROVIDER`, `CODACY_ORG_NAME`, `CODACY_REPO_NAME`, `RESULT_UPLOAD_URL`. The script fails fast
if any are missing.

## What's inside

- `codacy` — Codacy Cloud CLI
- `codacy-analysis` — Codacy Analysis CLI (used by the skill only for config-file operations)
- `claude` / `gemini` — AI assistants
- Java, Python 3, Ruby, Go 1.26, shellcheck
- Outbound firewall — allowlist for Claude, Gemini, and Codacy only. In production (k8s) the firewall
  is skipped and egress is enforced by NetworkPolicy at the cluster level instead.
