#!/bin/bash
# visibility: public
# PreToolUse hook: confirm `rm -r*` when ANY target resolves outside both $cwd and $HOME.
# Best-effort token parsing; over-prompts on ambiguous cases, never under-prompts on absolute paths.

set -uo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')

[ -z "$CMD" ] && exit 0

# Match: rm with -r, -R, or --recursive somewhere
if ! printf '%s' "$CMD" | grep -qE '(^|[[:space:]]|[;|&])rm[[:space:]]+([^;|&]*[[:space:]]+)?(-[A-Za-z]*[rR][A-Za-z]*|--recursive)([[:space:]]|$)'; then
  exit 0
fi

HOME_REAL=$(cd "$HOME" 2>/dev/null && pwd -P) || HOME_REAL="$HOME"
CWD_REAL=$(cd "${CWD:-.}" 2>/dev/null && pwd -P) || CWD_REAL="${CWD:-$(pwd)}"

is_inside() {
  case "$1" in "$2"|"$2"/*) return 0;; *) return 1;; esac
}

is_catastrophic() {
  # macOS symlinks /etc, /tmp, /var into /private/*. After perl abs_path canonicalizes,
  # /etc/foo becomes /private/etc/foo. Strip the /private prefix before pattern-matching
  # so both canonical and symlink-relative paths match.
  local p="$1"
  case "$p" in /private/*) p="${p#/private}";; esac
  case "$p" in
    /|/usr|/usr/*|/etc|/etc/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/System|/System/*|/Library|/Library/*|/Applications|/Applications/*|/opt|/opt/*|/boot|/boot/*|/root|/root/*) return 0;;
    *) return 1;;
  esac
}

# Shared cache/state dirs inside $HOME. Wiping these has cross-repo blast radius;
# prefer scoped equivalents (pre-commit gc, brew cleanup, npm cache clean) instead.
is_shared_cache() {
  local p="$1"
  case "$p" in
    "$HOME_REAL/.cache"|"$HOME_REAL/.cache/"*) return 0;;
    "$HOME_REAL/.npm"|"$HOME_REAL/.npm/"*) return 0;;
    "$HOME_REAL/.local/share"|"$HOME_REAL/.local/share/"*) return 0;;
    "$HOME_REAL/Library/Caches"|"$HOME_REAL/Library/Caches/"*) return 0;;
    "$HOME_REAL/.gradle"|"$HOME_REAL/.gradle/"*) return 0;;
    "$HOME_REAL/.m2"|"$HOME_REAL/.m2/"*) return 0;;
    *) return 1;;
  esac
}

CATASTROPHIC=""
DANGEROUS=""
while read -r tok; do
  [ -z "$tok" ] && continue
  case "$tok" in -*) continue;; esac
  tok="${tok//\"/}"; tok="${tok//\'/}"
  case "$tok" in
    "~") tok="$HOME";;
    "~/"*) tok="$HOME/${tok#\~/}";;
  esac
  case "$tok" in /*) abs="$tok";; *) abs="$CWD_REAL/$tok";; esac
  abs=$(perl -MCwd=abs_path -e 'print abs_path($ARGV[0]) // $ARGV[0]' "$abs" 2>/dev/null || printf '%s' "$abs")
  if is_catastrophic "$abs"; then
    CATASTROPHIC="${CATASTROPHIC}${abs}"$'\n'
  elif is_shared_cache "$abs"; then
    DANGEROUS="${DANGEROUS}${abs} (shared cache, cross-repo blast radius)"$'\n'
  elif ! is_inside "$abs" "$HOME_REAL" && ! is_inside "$abs" "$CWD_REAL"; then
    DANGEROUS="${DANGEROUS}${abs}"$'\n'
  fi
done < <(printf '%s\n' "$CMD" | awk '
  { for (i = 1; i <= NF; i++) {
      if ($i == "rm") { in_rm = 1; continue }
      if ($i ~ /^[;|&]+$/) { in_rm = 0; continue }
      if (in_rm) print $i
    }
  }')

if [ -n "$CATASTROPHIC" ]; then
  REASON="rm -r on system path (refusing, no Allow option):
$(printf '%s' "$CATASTROPHIC" | sed 's/^/  - /')"
  jq -n --arg reason "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  exit 0
fi

[ -z "$DANGEROUS" ] && exit 0

REASON="rm -r targeting paths outside cwd and home:
$(printf '%s' "$DANGEROUS" | sed 's/^/  - /')"

printf '%s' "$INPUT" | exec bash "$CLAUDE_CONFIG_DIR/hooks/confirm-dialog.sh" '.+' "$REASON"
