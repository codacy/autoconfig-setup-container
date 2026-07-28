#!/bin/bash
# Removes repository-controlled AI-agent configuration from a workspace and scrubs
# embedded credentials from git remotes.

set -uo pipefail

WORKSPACE="${1:?usage: sanitize-workspace.sh <workspace-dir>}"

if [[ ! -d "${WORKSPACE}" ]]; then
  echo "ERROR: sanitize-workspace: '${WORKSPACE}' is not a directory" >&2
  exit 1
fi

cd "${WORKSPACE}" || exit 1

removed=0

while IFS= read -r -d '' path; do
  if rm -rf -- "${path}" 2>/dev/null; then
    removed=$((removed + 1))
  fi
done < <(find . -name .git -prune -o \
  -type d \( -name '.claude' -o -name '.gemini' \) -print0 2>/dev/null)

while IFS= read -r -d '' path; do
  if rm -f -- "${path}" 2>/dev/null; then
    removed=$((removed + 1))
  fi
done < <(find . -name .git -prune -o \
  -type f \( -name '.mcp.json' -o -name 'CLAUDE.md' -o -name 'CLAUDE.local.md' \
             -o -name 'GEMINI.md' -o -name 'AGENTS.md' \) -print0 2>/dev/null)

echo "==> Sanitized workspace: removed ${removed} repository-controlled agent config path(s)"

scrub_remote_url() {
  local url="$1" proto rest authority path host
  case "${url}" in
    *://*) ;;
    *) printf '%s' "${url}"; return 0 ;;
  esac
  proto="${url%%://*}"
  rest="${url#*://}"
  authority="${rest%%/*}"
  path="${rest#*/}"
  if [[ "${authority}" != *@* ]]; then
    printf '%s' "${url}"
    return 0
  fi
  host="${authority##*@}"
  printf '%s://%s/%s' "${proto}" "${host}" "${path}"
}

if git rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r remote; do
    [[ -n "${remote}" ]] || continue
    url=$(git remote get-url "${remote}" 2>/dev/null) || continue
    scrubbed=$(scrub_remote_url "${url}")
    if [[ "${scrubbed}" != "${url}" ]]; then
      if git remote set-url "${remote}" "${scrubbed}" 2>/dev/null; then
        echo "==> Scrubbed embedded credentials from git remote '${remote}'"
      else
        echo "ERROR: sanitize-workspace: failed to scrub remote '${remote}'" >&2
        exit 1
      fi
    fi
  done < <(git remote 2>/dev/null)

  git config --local --unset-all http.extraheader 2>/dev/null || true

  while IFS= read -r line; do
    url="${line#* }"
    if [[ "$(scrub_remote_url "${url}")" != "${url}" ]]; then
      echo "ERROR: sanitize-workspace: credentials still present in .git/config" >&2
      exit 1
    fi
  done < <(git config --local --get-regexp '^remote\..*\.url$' 2>/dev/null)
fi

exit 0
