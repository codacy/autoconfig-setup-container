# codacy/autoconfig

Set `SOURCE_PATH` in `.env` (or export it), then:

```bash
docker compose run --rm codacy-ai
```

Required env vars: `CODACY_API_TOKEN`, and `ANTHROPIC_API_KEY` or `GEMINI_API_KEY` (or both).

> **Docker Desktop users:** set Memory to at least 12 GB in Settings → Resources → Memory. Analysis peaks at ~10.5 GB.

Or from any folder, without the compose file:

```bash
docker run --rm -it \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  --device /dev/kmsg:/dev/kmsg \
  --memory=12g --memory-swap=12g \
  -v codacy-tool-cache:/home/node/.codacy \
  -v $(pwd):/workspace \
  -e CODACY_API_TOKEN -e ANTHROPIC_API_KEY -e GEMINI_API_KEY \
  codacy/autoconfig
```

Or with an explicit env file:

```bash
docker run --rm -it \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  --device /dev/kmsg:/dev/kmsg \
  --memory=12g --memory-swap=12g \
  -v codacy-tool-cache:/home/node/.codacy \
  -v $(pwd):/workspace \
  --env-file /path/to/.env \
  codacy/autoconfig
```

| Flag | Purpose |
|---|---|
| `--rm` | Delete the container on exit |
| `-it` | Interactive terminal |
| `--cap-add=NET_ADMIN --cap-add=NET_RAW` | Required to enforce the outbound firewall inside the container |
| `--device /dev/kmsg:/dev/kmsg` | Kernel device needed by the firewall setup |
| `--memory=12g --memory-swap=12g` | Cap memory at 12 GB, no swap (analysis peaks ~10.5 GB) |
| `-v codacy-tool-cache:/home/node/.codacy` | Persistent volume so downloaded tools survive between runs |
| `-v $(pwd):/workspace` | Mounts your current folder as `/workspace` |
| `-e ...` | Passes API tokens from your host environment into the container |
| `--env-file /path/to/.env` | Alternative to `-e` flags — loads vars from a file |

To rebuild the image:

```bash
docker compose build
```

## What's inside

- `codacy` — Codacy Cloud CLI
- `codacy-analysis` — runs static analysis tools locally (trivy, ruff, opengrep, pmd, checkov, etc., downloaded on first use)
- `claude` / `gemini` — AI assistants
- Java 21, Python 3.12, Ruby, Go 1.26, shellcheck
- Outbound firewall — allowlist only (GitHub, Codacy, Anthropic, Google, npm, PyPI)
