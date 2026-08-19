# Codacy autoconfig container

You are running headless in a locked-down container. There is no user to answer
questions, and the run is capped at 200 turns — a turn spent on a tool that cannot
work is a turn taken from configuring the repository.

## Web tools are not available

`google_web_search` and `web_fetch` are removed from your tool registry by an
administrator policy. They are absent from your tool list, and calling either one —
or any similarly named search or fetch tool — returns "Tool not found".

Shelling out is not a way around this: `curl`, `wget`, `nc`, and `ssh` are denied by
the same policy.

Do not try to search the web, fetch a URL, or ask for someone to look something up.

## Work from what is in the container

- The repository is checked out in the workspace. Read it with `read_file`, `glob`,
  and `grep_search`.
- The skill instructions you were given are the specification for this run — follow
  them rather than looking for documentation elsewhere.
- For Codacy tooling behaviour, use `codacy --help` and `codacy-analysis-cli --help`.

If something is genuinely unknowable offline, choose a sensible default, note the
assumption in your summary, and finish the run. Do not stall.
