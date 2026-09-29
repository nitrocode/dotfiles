#!/bin/bash
# visibility: public
# PreToolUse hook: block dangerous commands unless explicitly confirmed
# Returns a "deny" decision with explanation when a dangerous pattern is detected.

set -euo pipefail

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$CMD" ]; then
  exit 0
fi

REASON=""

# rm -r* policy lives in rm-confirm.sh (catastrophic paths → deny, outside cwd/home → dialog).

# --- Git destructive operations ---
if echo "$CMD" | grep -qE 'git\s+push\s+.*--force(\s|$)'; then
  REASON="Blocked: force push can overwrite remote history."
elif echo "$CMD" | grep -qE 'git\s+push\s+.*-f(\s|$)'; then
  REASON="Blocked: force push (-f) can overwrite remote history."
elif echo "$CMD" | grep -qE 'git\s+reset\s+--hard'; then
  REASON="Blocked: git reset --hard discards uncommitted changes."
elif echo "$CMD" | grep -qE 'git\s+clean\s+.*-f'; then
  REASON="Blocked: git clean -f permanently deletes untracked files."
elif echo "$CMD" | grep -qE 'git\s+checkout\s+--\s+\.'; then
  REASON="Blocked: git checkout -- . discards all unstaged changes."
elif echo "$CMD" | grep -qE 'git\s+branch\s+.*-D'; then
  REASON="Blocked: git branch -D force-deletes a branch without merge check."

# --- Docker destructive operations ---
elif echo "$CMD" | grep -qE 'docker\s+push'; then
  REASON="Blocked: docker push publishes an image to a registry."
elif echo "$CMD" | grep -qE 'docker\s+system\s+prune'; then
  REASON="Blocked: docker system prune removes all unused data."
elif echo "$CMD" | grep -qE 'docker\s+rm\s+.*-f'; then
  REASON="Blocked: docker rm -f force-removes running containers."

# kubectl delete/drain and terraform destroy moved to confirm-dialog.sh (Allow/Deny via dialog).

# --- Terraform / Atmos: auto-approve still hard-denied (bypasses TF's own prompt) ---
elif echo "$CMD" | grep -qE 'terraform\s+apply\s+.*-auto-approve'; then
  REASON="Blocked: terraform apply -auto-approve skips confirmation."
elif echo "$CMD" | grep -qE 'atmos\s+terraform\s+apply\s+.*-auto-approve'; then
  REASON="Blocked: atmos terraform apply -auto-approve skips confirmation."

fi

# --- Confirmation-required patterns (ask, do not deny) ---
# Package installs: not destructive but worth a pause to verify package + source
# (supply-chain risk). Lockfile-driven installs (no new package named, resolved
# entirely from an existing requirements.txt/package.json) skip the ask, since
# there's no new package to vet.
ASK_REASON=""
if [ -z "$REASON" ]; then
  if echo "$CMD" | grep -qE '(^|[;&|]\s*)pip3?\s+install\b'; then
    if ! echo "$CMD" | grep -qE '(^|[;&|]\s*)pip3?\s+install\s+.*(-r|--requirement)\b'; then
      ASK_REASON="Confirm pip install: verify the package name and source (supply chain)."
    fi
  elif echo "$CMD" | grep -qE '(^|[;&|]\s*)npm\s+(install|i|add)\b'; then
    if echo "$CMD" | grep -qE '(^|[;&|]\s*)npm\s+(install|i)\s*(-[A-Za-z-]+(=[^[:space:]]*)?[[:space:]]*)*($|[;&|])'; then
      : # bare "npm install"/"npm i" (+flags only, no package) reads from package.json, no ask
    else
      ASK_REASON="Confirm npm install: verify package.json or the explicit package (supply chain)."
    fi
  elif echo "$CMD" | grep -qE '(^|[;&|]\s*)brew\s+install\b'; then
    ASK_REASON="Confirm brew install: adds a system-level dependency."
  fi
fi

if [ -n "$ASK_REASON" ]; then
  jq -n --arg reason "$ASK_REASON" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "ask",
      "permissionDecisionReason": $reason
    }
  }'
  exit 0
fi

# If no dangerous pattern matched, allow silently
if [ -z "$REASON" ]; then
  exit 0
fi

# Block the command with explanation
jq -n \
  --arg reason "$REASON" \
  '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": $reason
    }
  }'
