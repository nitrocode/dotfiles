#!/usr/bin/env bash
# gdoc-apply-edits.sh
#
# Apply a structured edit-list to a Google Doc via the bound Apps Script.
# Preserves existing doc formatting (uses DocumentApp native APIs, not
# markdown-to-doc conversion).
#
# Usage:
#   gdoc-apply-edits.sh --doc-id <ID> --edits <FILE.json>
#   gdoc-apply-edits.sh --doc-id <ID> --edits-stdin < edits.json
#
# Edits-file shape:
#   [
#     {"type": "replace", "find": "3 Flavors", "replace": "4 Flavors"},
#     {"type": "insertSectionAfter", "afterHeading": "Flow 3: Non-Code...",
#      "paragraphs": [
#        {"text": "Flow 4: Restricted Read-Access Repositories", "heading": "HEADING1"},
#        {"text": "Standard: ...", "heading": "NORMAL"}
#      ]}
#   ]
#
# Setup: see ~/.claude/scripts/gdoc-apply-edits/README.md
#
# Dependencies: clasp (npm i -g @google/clasp), jq.
set -euo pipefail

PROJECT_DIR="$CLAUDE_CONFIG_DIR/scripts/gdoc-apply-edits"

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}

DOC_ID=""
EDITS_FILE=""
EDITS_STDIN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --doc-id) DOC_ID="$2"; shift 2 ;;
    --edits) EDITS_FILE="$2"; shift 2 ;;
    --edits-stdin) EDITS_STDIN=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

[[ -n "$DOC_ID" ]] || { echo "error: --doc-id required" >&2; usage; }

if [[ $EDITS_STDIN -eq 1 ]]; then
  EDITS_JSON="$(cat)"
elif [[ -n "$EDITS_FILE" ]]; then
  [[ -f "$EDITS_FILE" ]] || { echo "error: edits file not found: $EDITS_FILE" >&2; exit 2; }
  EDITS_JSON="$(cat "$EDITS_FILE")"
else
  echo "error: --edits FILE or --edits-stdin required" >&2
  usage
fi

# Validate JSON shape: must be an array.
if ! printf '%s' "$EDITS_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "error: edits JSON must be a top-level array" >&2
  exit 2
fi

# Verify clasp is available unless tests override the binary path.
CLASP_BIN="${CLASP_BIN:-clasp}"
if ! command -v "$CLASP_BIN" >/dev/null 2>&1; then
  echo "error: clasp not installed (npm i -g @google/clasp)" >&2
  exit 3
fi

[[ -d "$PROJECT_DIR" ]] || { echo "error: project dir missing: $PROJECT_DIR" >&2; exit 3; }

# Build payload as a single-element array (clasp run --params expects an array
# of function arguments).
PAYLOAD="$(jq -nc --arg docId "$DOC_ID" --argjson edits "$EDITS_JSON" \
  '[{docId: $docId, edits: $edits}]')"

cd "$PROJECT_DIR"
exec "$CLASP_BIN" run applyEdits --params "$PAYLOAD"
