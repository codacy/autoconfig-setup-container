# codacy/autoconfig

Set `SOURCE_PATH` in `.env` (or export it), then:

```bash
docker compose run --rm codacy-ai
```

Required env vars: `CODACY_API_TOKEN` and `ANTHROPIC_API_KEY`.

The repository at `SOURCE_PATH` must already be on Codacy Cloud with at least one finished analysis. The container tunes
the cloud configuration via Cloud reanalysis — it does not run local analysis, and it does not import not-yet-on-Codacy
repositories.

Or from any folder, without the compose file:

```bash
docker run --rm -it \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  --device /dev/kmsg:/dev/kmsg \
  -v codacy-tool-cache:/home/runner/.codacy \
  -v $(pwd):/workspace \
  -e CODACY_API_TOKEN -e ANTHROPIC_API_KEY \
  codacy/autoconfig
```

Or with an explicit env file:

```bash
docker run --rm -it \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  --device /dev/kmsg:/dev/kmsg \
  -v codacy-tool-cache:/home/runner/.codacy \
  -v $(pwd):/workspace \
  --env-file ./../.env \
  codacy/autoconfig
```

| Flag                                      | Purpose                                                         |
|-------------------------------------------|-----------------------------------------------------------------|
| `--rm`                                    | Delete the container on exit                                    |
| `-it`                                     | Interactive terminal                                            |
| `--cap-add=NET_ADMIN --cap-add=NET_RAW`   | Required to enforce the outbound firewall inside the container  |
| `--device /dev/kmsg:/dev/kmsg`            | Kernel device needed by the firewall block-log stream           |
| `-v codacy-tool-cache:/home/runner/.codacy` | Persistent volume so downloaded tools survive between runs      |
| `-v $(pwd):/workspace`                    | Mounts your current folder as `/workspace`                      |
| `-e ...`                                  | Passes API tokens from your host environment into the container |
| `--env-file /path/to/.env`                | Alternative to `-e` flags — loads vars from a file              |

To rebuild the image:

```bash
docker compose build
```

## Two pipelines, local and server

The image ships two entrypoint scripts:

- `local-pipeline.sh` (default). For developers running the container against a mounted source folder. Used by
  `docker compose` and the `docker run` examples above. Invokes `/configure-codacy-cloud` against `/workspace`.
- `server-pipeline.sh`. For the Active Analysis Manager (AAM) in production. Clones the repository via `GIT_TOKEN`,
  invokes `/configure-codacy-cloud`, and uploads a JSONL summary to a presigned S3 URL. The clone URL is built per
  provider (`CODACY_PROVIDER` of `gh`/`ghe` for GitHub, `gl`/`gle` for GitLab, `bb` for Bitbucket).

Both scripts run the same skill. The skill tunes a repository's Codacy Cloud configuration via Cloud reanalysis and
never runs local static analysis tools — that's why the container's egress allowlist is narrow (Claude + Codacy).

To test `server-pipeline.sh` locally, override the entrypoint and provide the additional env vars. Note that the
local firewall does not allow git provider hosts, so set `RUNNING_IN_K8S=true` to skip it for this test:

```bash
docker run --rm -it \
  -v codacy-tool-cache:/home/runner/.codacy \
  -e RUNNING_IN_K8S=true \
  -e CODACY_API_TOKEN \
  -e ANTHROPIC_API_KEY \
  -e GIT_TOKEN \
  -e CODACY_PROVIDER=gh \
  -e CODACY_ORG_NAME=your-org \
  -e CODACY_REPO_NAME=your-repo \
  -e RESULT_UPLOAD_URL=https://httpbin.org/put \
  --entrypoint /usr/local/bin/server-pipeline.sh \
  codacy/autoconfig
```

`httpbin.org/put` accepts any PUT and is useful for smoke-testing the upload step.

To capture the summary on your host instead of sending it to httpbin, run a tiny HTTP sink in another terminal:

```bash
python3 -c "
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_PUT(self):
        n = int(self.headers.get('Content-Length', 0))
        open('summary.received.jsonl', 'wb').write(self.rfile.read(n))
        self.send_response(200); self.end_headers()
http.server.HTTPServer(('0.0.0.0', 8080), H).serve_forever()
"
```

Then point the container at it with `RESULT_UPLOAD_URL=http://host.docker.internal:8080/upload`.

Required env vars for the server pipeline: `CODACY_API_TOKEN`, `ANTHROPIC_API_KEY`, `GIT_TOKEN`, `CODACY_PROVIDER`,
`CODACY_ORG_NAME`, `CODACY_REPO_NAME`, `RESULT_UPLOAD_URL`. The script fails fast if any are missing.

## What's inside

- `codacy` — Codacy Cloud CLI
- `codacy-analysis` — Codacy Analysis CLI (used by the skill only for config-file operations)
- `claude` — AI assistant (runs on Haiku, `--permission-mode dontAsk`). `gemini` is installed but no longer used.
- Java, Python 3, Ruby, Go 1.26, shellcheck
- Outbound firewall — IP allowlist plus a DNS allowlist (Claude + Codacy hosts, incl. `app.dev`/`app.staging.codacy.org`);
  non-allowlisted DNS is sinkholed. In production (k8s) the firewall is skipped and egress is enforced by NetworkPolicy.
- **Least-privilege agent (OD-78):** two OS users — `runner` holds the secrets (Codacy credentials + an Anthropic auth
  proxy), `agent` runs Claude with no readable secret and reaches the Codacy CLIs only through `sudo` shims. So a
  prompt-injected agent has nothing to exfiltrate. See `docs/hardening-overview.md`; verify with `./docker/test-hardening.sh`.
