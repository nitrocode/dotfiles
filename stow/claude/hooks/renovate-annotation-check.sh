#!/bin/bash
# visibility: public
# PostToolUse hook: warn on hardcoded semantic versions missing a Renovate
# annotation in files Renovate's built-in managers do NOT cover.
#
# Scope (per user preference): only checks
#   - .github/workflows/*.yml(.yaml)
#   - .github/actions/*/action.yml(.yaml)
#   - Makefile, *.mk
#   - *.sh, *.bash
#   - Dockerfile (and Dockerfile.*)
#
# Skipped (Renovate built-in or custom manager already handles them):
#   - requirements*.txt, Pipfile*, pyproject.toml, setup.py, setup.cfg
#   - package.json, package-lock.json, yarn.lock, pnpm-lock.yaml
#   - go.mod, go.sum
#   - Cargo.toml, Cargo.lock
#   - Chart.yaml, Chart.lock
#   - Gemfile, Gemfile.lock
#
# A version line is OK if it carries one of:
#   - inline:  `... = "1.2.3" # renovate: datasource=... depName=...`
#   - inline:  `... v1.2.3 # renovate: datasource=... depName=...`
#   - comment-before-version (YAML pattern):
#       # renovate: datasource=... depName=...
#       FOO_VERSION: "1.2.3"
#
# Otherwise emits a WARNING listing file:line and suggested annotation.
# Non-blocking; never modifies the file.

set -uo pipefail

INPUT=$(cat)
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_response.filePath // .tool_input.file_path // empty' 2>/dev/null)

if [[ -z "$FILE" || "$FILE" == "null" || ! -f "$FILE" ]]; then
  exit 0
fi

# In-scope file types only.
case "$FILE" in
  *.github/workflows/*.yml|*.github/workflows/*.yaml) ;;
  *.github/actions/*/action.yml|*.github/actions/*/action.yaml) ;;
  */Makefile|*/Makefile.*|Makefile|Makefile.*) ;;
  *.mk) ;;
  *.sh|*.bash) ;;
  */Dockerfile|*/Dockerfile.*|Dockerfile|Dockerfile.*) ;;
  *) exit 0 ;;
esac

# Skip files that Renovate's built-in or already-configured custom managers
# cover (belt-and-suspenders; the case above is the primary filter).
case "$(basename "$FILE")" in
  requirements*.txt|Pipfile|Pipfile.lock|pyproject.toml|setup.py|setup.cfg) exit 0 ;;
  package.json|package-lock.json|yarn.lock|pnpm-lock.yaml) exit 0 ;;
  go.mod|go.sum) exit 0 ;;
  Cargo.toml|Cargo.lock) exit 0 ;;
  Chart.yaml|Chart.lock) exit 0 ;;
  Gemfile|Gemfile.lock) exit 0 ;;
esac

# Patterns that look like hardcoded semantic versions.
# Group conventions:
#   pattern is a Python-flavored regex string, but we'll use awk so use POSIX ERE.

# A line has an inline renovate annotation if it contains `# renovate: datasource= depName=`.
# A preceding line (previous output line) with renovate annotation also counts.

WARNS=()

prev_line=""
lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))

  # Skip the line itself if it's a pure comment (annotation lives elsewhere).
  trimmed="${line#"${line%%[![:space:]]*}"}"
  if [[ "$trimmed" == \#* ]]; then
    prev_line="$line"
    continue
  fi

  # Skip SHA-pinned GitHub Actions `uses:` lines (Renovate built-in covers
  # them, and the # vX tag-comment is not a Renovate annotation).
  if [[ "$line" =~ uses:[[:space:]]+[A-Za-z0-9_./-]+@[0-9a-f]{40}([[:space:]]+\#[[:space:]]*v?[0-9.]+)? ]]; then
    prev_line="$line"
    continue
  fi

  # Detect version-like patterns we care about. Conservative set:
  #   1) <FOO>_VERSION = "1.2.3" / FOO_VERSION: 1.2.3
  #   2) --version v1.2.3 / --version 1.2.3
  #   3) version: v1.2.3 (YAML literal pin)
  #   4) ARG/ENV FOO=1.2.3 (Dockerfile)
  matched=0
  if [[ "$line" =~ ([A-Z][A-Z0-9_]*_VERSION)[[:space:]]*[:=][[:space:]]*[\"\']?v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    matched=1
  elif [[ "$line" =~ --version[[:space:]]+v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    matched=1
  elif [[ "$line" =~ ^[[:space:]]*version:[[:space:]]+[\"\']?v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    matched=1
  elif [[ "$line" =~ ^[[:space:]]*(ARG|ENV)[[:space:]]+[A-Z_]+_VERSION[[:space:]]*=[\"\']?v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    matched=1
  fi

  if (( matched )); then
    # Already annotated?
    if [[ "$line" =~ \#[[:space:]]*renovate:[[:space:]]+datasource= ]] || \
       [[ "$prev_line" =~ \#[[:space:]]*renovate:[[:space:]]+datasource= ]]; then
      prev_line="$line"
      continue
    fi
    WARNS+=("$FILE:$lineno: $trimmed")
  fi

  prev_line="$line"
done < "$FILE"

if (( ${#WARNS[@]} > 0 )); then
  {
    printf '⚠️  Hardcoded version(s) missing Renovate annotation in %s:\n' "$FILE"
    for w in "${WARNS[@]}"; do printf '  - %s\n' "$w"; done
    printf 'Add a comment like:\n'
    printf '  inline:           VECTOR_VERSION="0.46.1" # renovate: datasource=github-releases depName=vectordotdev/vector\n'
    printf '  comment-before:   # renovate: datasource=github-releases depName=helm/helm\n'
    printf '                    HELM_VERSION: "3.16.2"\n'
    printf 'See ~/git/work/renovate-config/custom-managers.json5 for the regex managers that pick these up.\n'
  } >&2
fi

exit 0
