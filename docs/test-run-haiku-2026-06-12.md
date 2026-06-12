# Test run — `--model haiku` end-to-end (2026-06-12)

First successful end-to-end run of the local pipeline after adding `--model haiku`
to the `configure-codacy-cloud` invocation. Confirms the skill completes a full
baseline → first-pass tuning → import → reanalysis cycle on Haiku.

## Command

```bash
docker run --rm -it \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  --device /dev/kmsg:/dev/kmsg \
  -v codacy-tool-cache:/home/node/.codacy \
  -v /Users/czak/GIT/codacy/testing/troubleshoot-codacy-dev/access-test:/workspace \
  --env-file ./../.env \
  codacy/autoconfig
```

The mounted repo (`access-test`) is a git checkout already on Codacy — a small
JS demo (`README.md`, `src/calculator.js`, `coverage/cobertura.xml`).

## Outcome

- Firewall initialized (claude + gemini + codacy); block monitor started.
- Prerequisites verified: repo on Codacy, issue data present (27 issues) despite a
  `null` `lastAnalysed` field — the skill correctly treated the issue overview as
  proof of a finished analysis and proceeded.
- Coding standard present ("AI Usage Compliance 4"); no tool was standard-enforced
  (`enabledBy: []`), so all tools were changeable. No 409 conflicts on import.
- First-pass config imported to Codacy Cloud; reanalysis triggered (ran in the
  background — can take up to ~20 min).

## Baseline

27 issues — Security 13, UnusedCode 10, ErrorProne 2, CodeStyle 2.
Languages: JavaScript, Markdown, XML. BEFORE: 7 tools, 1006 patterns.

> Note: the cloud issues were from a previously-analyzed, deliberately-vulnerable
> version of `calculator.js`; the current working tree is a trivial 26-line file.
> Config tuning is still valid against the cloud baseline.

## First-pass config applied (imported to Codacy Cloud)

| Tool                | Before | After |
|---------------------|-------:|------:|
| Semgrep (Opengrep)  |    645 |   484 |
| ESLint8             |    184 |   181 |
| PMD                 |    123 |   123 |
| markdownlint        |     43 |    43 |
| Agentlinter         |      1 |    27 |
| Trivy               |      6 |     6 |
| Lizard              |      4 |     4 |
| **Total**           | **1006** | **868** |

## Cuts made

- **Rejected 6 wrong-stack / redundant tools** the auto-config proposed: Checkov
  (IaC), spectral (OpenAPI), jackson (Java) — no such files; Biome, ESLint9, PMD7 —
  redundant with the established ESLint8 / PMD.
- **Trimmed ~549 wrong-language Semgrep patterns** (Python / Java / Terraform / Ruby /
  Go / C# / Scala / PHP …) on a JS-only repo; kept JS + generic secret-scanning +
  curated packs. Also trimmed non-JS subpacks of `problem-based-packs.insecure-transport`
  (java/go/ruby), kept `js-node`.
- **Disabled 3 noisy ESLint8 patterns:**
  - `detect-object-injection` (6) — array-index `items[i]` false positives (biggest single noise source).
  - `@typescript-eslint_no-unused-vars` (5) — exact duplicate of `no-unused-vars`; no TypeScript in repo.
  - `@typescript-eslint_prefer-for-of` (2) — CodeStyle/Info, TS rule on a JS repo.
- **Kept all genuine security findings:** hardcoded passwords, TLS bypass, XSS via
  `innerHTML`, `eval`, `no-undef`/`db`, `no-unused-vars`, PMD `EqualComparison`.

## Observations relevant to OD-78

- The agent again had `CODACY_API_TOKEN` available in its environment and used it for
  auth — the exact exposure the hardening removes.
- Haiku handled the full multi-step tool-use flow (jq parsing, config edits, import,
  background reanalysis) without getting stuck — no need to fall back to a larger model
  for this repo.
