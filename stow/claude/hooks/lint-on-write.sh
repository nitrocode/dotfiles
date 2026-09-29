#!/usr/bin/env bash
# visibility: public
# PostToolUse hook: lint shell/Terraform files after Write/Edit. Warn, do not block.
# Insights flagged buggy first-pass shell/TF code as recurring friction.

set -uo pipefail

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_response.filePath // .tool_input.file_path // empty')

if [[ -z "$FILE" || "$FILE" == "null" || ! -f "$FILE" ]]; then
  exit 0
fi

case "$FILE" in
  *.sh|*.bash|*.zsh)
    if command -v shellcheck >/dev/null 2>&1; then
      OUT=$(timeout 5 shellcheck --color=never "$FILE" 2>&1)
      if [ -n "$OUT" ]; then
        echo "WARNING: shellcheck on $FILE:" >&2
        echo "$OUT" | head -25 >&2
      fi
    fi
    ;;
  *.tf|*.tfvars)
    if command -v terraform >/dev/null 2>&1; then
      OUT=$(timeout 5 terraform fmt -check -diff "$FILE" 2>&1)
      if [ -n "$OUT" ]; then
        echo "WARNING: terraform fmt drift on $FILE (run \`terraform fmt $FILE\` to fix):" >&2
        echo "$OUT" | head -25 >&2
      fi
    fi
    ;;
  *.go)
    if command -v gofmt >/dev/null 2>&1; then
      OUT=$(timeout 5 gofmt -l -w "$FILE" 2>&1)
      if [ -n "$OUT" ]; then
        echo "WARNING: gofmt reformatted $FILE" >&2
      fi
    fi
    if command -v go >/dev/null 2>&1; then
      OUT=$(cd "$(dirname "$FILE")" && timeout 8 go vet ./... 2>&1)
      if [ -n "$OUT" ]; then
        echo "WARNING: go vet issues in $(dirname "$FILE"):" >&2
        echo "$OUT" | head -25 >&2
      fi
    fi
    ;;
  *.yml|*.yaml)
    if command -v yamllint >/dev/null 2>&1; then
      OUT=$(timeout 5 yamllint "$FILE" 2>&1)
      if [ -n "$OUT" ]; then
        echo "WARNING: yamllint on $FILE:" >&2
        echo "$OUT" | head -25 >&2
      fi
    fi
    ;;
esac

exit 0
