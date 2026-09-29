#!/bin/bash
# visibility: public
# PostToolUse hook: auto-format YAML files after Write|Edit

FILE=$(jq -r '.tool_response.filePath // .tool_input.file_path' 2>/dev/null)

if [[ -z "$FILE" || "$FILE" == "null" ]]; then
    exit 0
fi

if ! command -v prettier >/dev/null 2>&1; then
    exit 0
fi

if [[ "$FILE" == *.yaml || "$FILE" == *.yml ]]; then
    prettier --write "$FILE" 2>/dev/null
fi
