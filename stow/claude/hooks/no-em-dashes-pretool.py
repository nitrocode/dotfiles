#!/usr/bin/env python3
# visibility: public
"""PreToolUse hook: auto-replace U+2014 in tool calls with commas.

Watched tools: Edit, Write, MultiEdit, Slack send/draft/schedule, Jira
create/edit/comment, Confluence create/update/comments. For non-watched
tools the hook exits 0 immediately.

When U+2014 is found in any writable string value of tool_input outside
fenced code blocks, the hook replaces it with comma+space and allows the
call through with the corrected payload (modifiedInput).

U+2014 inside fenced code blocks (triple-backtick) is preserved.
U+2014 inside read-only fields (Edit.old_string, MultiEdit.edits[].old_string,
file_path) is preserved so existing file content can still be matched.

Local-only files nobody else will see (plan docs under $CLAUDE_CONFIG_DIR/plans/,
session scratchpad dirs) are exempt entirely for Edit/Write/MultiEdit: the
rule exists for content that gets read by someone else, and these don't.

Input (stdin): JSON event {tool_name, tool_input, ...}.
Output (stdout): hookSpecificOutput JSON with modifiedInput if found, or empty when allowing.
"""

import json
import os
import re
import sys

FILE_PATH_TOOLS = {"Edit", "Write", "MultiEdit"}

EXEMPT_PATH_PREFIXES = (
    os.path.expanduser("$CLAUDE_CONFIG_DIR/plans/"),
)
EXEMPT_PATH_SUBSTRINGS = (
    "/scratchpad/",
)


def is_exempt_file_path(tool_input):
    """True if tool_input.file_path is a local-only plan/scratch path."""
    file_path = tool_input.get("file_path", "")
    if not isinstance(file_path, str) or not file_path:
        return False
    if any(file_path.startswith(p) for p in EXEMPT_PATH_PREFIXES):
        return True
    return any(s in file_path for s in EXEMPT_PATH_SUBSTRINGS)

WATCHED = {
    "Edit",
    "Write",
    "MultiEdit",
    "mcp__plugin_slack_slack__slack_send_message",
    "mcp__plugin_slack_slack__slack_send_message_draft",
    "mcp__plugin_slack_slack__slack_schedule_message",
    "mcp__plugin_atlassian_atlassian__createJiraIssue",
    "mcp__plugin_atlassian_atlassian__editJiraIssue",
    "mcp__plugin_atlassian_atlassian__addCommentToJiraIssue",
    "mcp__plugin_atlassian_atlassian__createConfluencePage",
    "mcp__plugin_atlassian_atlassian__updateConfluencePage",
    "mcp__plugin_atlassian_atlassian__createConfluenceFooterComment",
    "mcp__plugin_atlassian_atlassian__createConfluenceInlineComment",
}

# Subtrees rooted at these keys are skipped (read-only / not written content).
# Applies recursively: any value whose dict key is in the set is left alone.
SKIP_KEYS_PER_TOOL = {
    "Edit": frozenset({"old_string", "file_path"}),
    "MultiEdit": frozenset({"old_string", "file_path"}),
    "Write": frozenset({"file_path"}),
}

EM_DASH = chr(0x2014)
FENCE_RE = re.compile(r"```[\s\S]*?```")
EM_DASH_SUB_RE = re.compile(r" *" + EM_DASH + r" *")


def replace_em_outside_fences(text):
    """Replace U+2014 outside fenced code blocks.

    Collapses surrounding spaces: ' U+2014 ' becomes ', ' (single space).
    Returns (new_text, found_any).
    """
    parts = []
    found = False
    last = 0
    for m in FENCE_RE.finditer(text):
        before = text[last:m.start()]
        if EM_DASH in before:
            found = True
            before = EM_DASH_SUB_RE.sub(", ", before)
        parts.append(before)
        parts.append(m.group(0))
        last = m.end()
    tail = text[last:]
    if EM_DASH in tail:
        found = True
        tail = EM_DASH_SUB_RE.sub(", ", tail)
    parts.append(tail)
    return "".join(parts), found


def walk_strings(node, skip_keys=frozenset()):
    """Walk a JSON tree, applying U+2014 replacement to every string.

    Subtrees rooted at keys in skip_keys are passed through unchanged.
    Returns (new_node, found_any).
    """
    if isinstance(node, dict):
        found = False
        new = {}
        for k, v in node.items():
            if k in skip_keys:
                new[k] = v
                continue
            nv, f = walk_strings(v, skip_keys)
            found = found or f
            new[k] = nv
        return new, found
    if isinstance(node, list):
        found = False
        new = []
        for v in node:
            nv, f = walk_strings(v, skip_keys)
            found = found or f
            new.append(nv)
        return new, found
    if isinstance(node, str):
        return replace_em_outside_fences(node)
    return node, False


def main():
    try:
        event = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    tool_name = event.get("tool_name", "")
    if tool_name not in WATCHED:
        sys.exit(0)

    tool_input = event.get("tool_input", {})
    if tool_name in FILE_PATH_TOOLS and is_exempt_file_path(tool_input):
        sys.exit(0)
    skip_keys = SKIP_KEYS_PER_TOOL.get(tool_name, frozenset())
    corrected, found = walk_strings(tool_input, skip_keys)
    if not found:
        sys.exit(0)

    decision = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "modifiedInput": corrected,
        }
    }
    print(json.dumps(decision))


if __name__ == "__main__":
    main()
