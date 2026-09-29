#!/usr/bin/env python3
# visibility: public
"""
Claude Code OTLP Trace Hook
Sends trace spans to any OTLP-compatible backend (SigNoz, Jaeger, Grafana, etc.)
via HTTP JSON.

Usage: echo '<hook_json>' | python3 otel-trace.py <event_type>

Events handled:
  SessionStart      -> creates root session span (saved, sent on SessionEnd)
  SessionEnd        -> completes session span
  UserPromptSubmit  -> creates user-turn span (child of session)
  Stop              -> completes user-turn span
  SubagentStop      -> creates completed subagent span (child of user-turn)
  PreToolUse        -> records tool span start (child of user-turn)
  PostToolUse       -> completes tool span and sends it

Span hierarchy:
  session (root)
    +-- user-turn (per prompt)
         +-- tool/* (per tool call)
         +-- subagent/* (per subagent completion)

Setup:
  1. Run an OTLP collector (e.g., `docker run -p 4318:4318 signoz/signoz`)
  2. Wire this script into settings.json hooks (see settings/settings.json)
  3. Set OTEL_HTTP_TRACES_ENDPOINT env var if not using localhost:4318
"""

import hashlib
import json
import os
import platform
import subprocess
import sys
import time
import secrets

TRACE_DIR = "/tmp/claude-otel-traces"
OTEL_HTTP_ENDPOINT = os.environ.get("OTEL_HTTP_TRACES_ENDPOINT", "http://localhost:4318")

# Max bytes for large attribute values (tool output, file content, etc.)
MAX_ATTR_BYTES = 4096
# Shorter limit for summary fields shown in span names / quick views
MAX_SUMMARY_BYTES = 500

RESOURCE_ATTRS = [
    {"key": "service.name", "value": {"stringValue": "claude-code"}},
    {"key": "deployment.environment", "value": {"stringValue": "local"}},
    {"key": "host.name", "value": {"stringValue": platform.node()}},
    {"key": "os.type", "value": {"stringValue": platform.system().lower()}},
    {"key": "os.version", "value": {"stringValue": platform.release()}},
]


def now_ns():
    return str(int(time.time() * 1e9))


def trace_id_from_session(session_id):
    return hashlib.md5(session_id.encode()).hexdigest()


def random_span_id():
    return secrets.token_hex(8)


def ensure_dir():
    os.makedirs(TRACE_DIR, exist_ok=True)


def read_state(name):
    path = os.path.join(TRACE_DIR, f"{name}.json")
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return None


def write_state(name, data):
    ensure_dir()
    with open(os.path.join(TRACE_DIR, f"{name}.json"), "w") as f:
        json.dump(data, f)


def delete_state(name):
    path = os.path.join(TRACE_DIR, f"{name}.json")
    if os.path.exists(path):
        os.remove(path)


def truncate(s, max_len=MAX_SUMMARY_BYTES):
    s = str(s)
    return s[:max_len] + "..." if len(s) > max_len else s


def str_attr(key, value):
    """Build a string attribute, truncating to MAX_ATTR_BYTES."""
    return {"key": key, "value": {"stringValue": truncate(str(value), MAX_ATTR_BYTES)}}


def int_attr(key, value):
    return {"key": key, "value": {"intValue": str(int(value))}}


def bool_attr(key, value):
    return {"key": key, "value": {"boolValue": bool(value)}}


def duration_ms(start_ns, end_ns):
    """Calculate duration in milliseconds from nanosecond strings."""
    return round((int(end_ns) - int(start_ns)) / 1_000_000, 2)


def send_span(trace_id, span_id, name, start_ns, end_ns, attributes,
              parent_span_id=None, kind=1, status_code=1, status_message="",
              events=None):
    span = {
        "traceId": trace_id,
        "spanId": span_id,
        "name": name,
        "kind": kind,
        "startTimeUnixNano": start_ns,
        "endTimeUnixNano": end_ns,
        "attributes": attributes,
        "status": {"code": status_code},
    }
    if status_message:
        span["status"]["message"] = status_message
    if parent_span_id:
        span["parentSpanId"] = parent_span_id
    if events:
        span["events"] = events

    payload = json.dumps({
        "resourceSpans": [{
            "resource": {"attributes": RESOURCE_ATTRS},
            "scopeSpans": [{
                "scope": {"name": "claude-code-hooks", "version": "1.0.0"},
                "spans": [span],
            }],
        }],
    })

    # Fire and forget -- don't block Claude
    subprocess.Popen(
        [
            "curl", "-s", "-X", "POST",
            f"{OTEL_HTTP_ENDPOINT}/v1/traces",
            "-H", "Content-Type: application/json",
            "-d", payload,
            "--connect-timeout", "2",
            "--max-time", "5",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


# -- Tool-specific metadata extractors ---------------------------------

def extract_bash_input(tool_input):
    """Extract rich metadata from Bash tool input."""
    attrs = []
    command = tool_input.get("command", "")
    attrs.append(str_attr("tool.bash.command", command))
    if tool_input.get("description"):
        attrs.append(str_attr("tool.bash.description", tool_input["description"]))
    if tool_input.get("timeout"):
        attrs.append(int_attr("tool.bash.timeout_ms", tool_input["timeout"]))
    if tool_input.get("run_in_background"):
        attrs.append(bool_attr("tool.bash.background", True))
    base_cmd = command.strip().split()[0] if command.strip() else ""
    attrs.append(str_attr("tool.bash.base_command", base_cmd))
    return attrs


def extract_read_input(tool_input):
    attrs = [str_attr("tool.file.path", tool_input.get("file_path", ""))]
    if tool_input.get("offset"):
        attrs.append(int_attr("tool.file.offset", tool_input["offset"]))
    if tool_input.get("limit"):
        attrs.append(int_attr("tool.file.limit", tool_input["limit"]))
    return attrs


def extract_write_edit_input(tool_input):
    attrs = [str_attr("tool.file.path", tool_input.get("file_path", ""))]
    if "content" in tool_input:
        attrs.append(int_attr("tool.file.content_length", len(tool_input["content"])))
        attrs.append(str_attr("tool.file.content_preview", tool_input["content"]))
    if "old_string" in tool_input:
        attrs.append(str_attr("tool.edit.old_string", tool_input["old_string"]))
        attrs.append(str_attr("tool.edit.new_string", tool_input.get("new_string", "")))
    if tool_input.get("replace_all"):
        attrs.append(bool_attr("tool.edit.replace_all", True))
    return attrs


def extract_glob_input(tool_input):
    attrs = [str_attr("tool.glob.pattern", tool_input.get("pattern", ""))]
    if tool_input.get("path"):
        attrs.append(str_attr("tool.glob.path", tool_input["path"]))
    return attrs


def extract_grep_input(tool_input):
    attrs = [str_attr("tool.grep.pattern", tool_input.get("pattern", ""))]
    if tool_input.get("path"):
        attrs.append(str_attr("tool.grep.path", tool_input["path"]))
    if tool_input.get("glob"):
        attrs.append(str_attr("tool.grep.file_glob", tool_input["glob"]))
    if tool_input.get("output_mode"):
        attrs.append(str_attr("tool.grep.output_mode", tool_input["output_mode"]))
    if tool_input.get("-i"):
        attrs.append(bool_attr("tool.grep.case_insensitive", True))
    return attrs


def extract_agent_input(tool_input):
    attrs = []
    if tool_input.get("prompt"):
        attrs.append(str_attr("tool.agent.prompt", tool_input["prompt"]))
    if tool_input.get("description"):
        attrs.append(str_attr("tool.agent.description", tool_input["description"]))
    if tool_input.get("subagent_type"):
        attrs.append(str_attr("tool.agent.type", tool_input["subagent_type"]))
    if tool_input.get("model"):
        attrs.append(str_attr("tool.agent.model", tool_input["model"]))
    if tool_input.get("run_in_background"):
        attrs.append(bool_attr("tool.agent.background", True))
    return attrs


TOOL_INPUT_EXTRACTORS = {
    "Bash": extract_bash_input,
    "Read": extract_read_input,
    "Write": extract_write_edit_input,
    "Edit": extract_write_edit_input,
    "Glob": extract_glob_input,
    "Grep": extract_grep_input,
    "Agent": extract_agent_input,
}


def extract_tool_input_attrs(tool_name, tool_input):
    """Extract tool-specific attributes, falling back to generic key dump."""
    extractor = TOOL_INPUT_EXTRACTORS.get(tool_name)
    if extractor:
        return extractor(tool_input)
    attrs = []
    for k, v in tool_input.items():
        attrs.append(str_attr(f"tool.input.{k}", v))
    return attrs


# -- Tool-specific response extractors ---------------------------------

def extract_bash_response(resp):
    attrs = []
    if isinstance(resp, dict):
        if "stdout" in resp:
            stdout = resp["stdout"]
            attrs.append(str_attr("tool.bash.stdout", stdout))
            attrs.append(int_attr("tool.bash.stdout_lines", stdout.count("\n") + (1 if stdout else 0)))
            attrs.append(int_attr("tool.bash.stdout_bytes", len(stdout)))
        if "stderr" in resp and resp["stderr"]:
            attrs.append(str_attr("tool.bash.stderr", resp["stderr"]))
        if "exit_code" in resp:
            attrs.append(int_attr("tool.bash.exit_code", resp["exit_code"]))
    return attrs


def extract_read_response(resp):
    attrs = []
    if isinstance(resp, dict):
        content = resp.get("content", "")
        if content:
            attrs.append(int_attr("tool.file.lines_read", content.count("\n")))
            attrs.append(int_attr("tool.file.bytes_read", len(content)))
            attrs.append(str_attr("tool.file.content_preview", content))
    elif isinstance(resp, str):
        attrs.append(int_attr("tool.file.lines_read", resp.count("\n")))
        attrs.append(int_attr("tool.file.bytes_read", len(resp)))
        attrs.append(str_attr("tool.file.content_preview", resp))
    return attrs


def extract_write_edit_response(resp):
    attrs = []
    if isinstance(resp, dict):
        if "filePath" in resp:
            attrs.append(str_attr("tool.file.result_path", resp["filePath"]))
        if "success" in resp:
            attrs.append(bool_attr("tool.file.success", resp["success"]))
    return attrs


def extract_glob_response(resp):
    attrs = []
    if isinstance(resp, list):
        attrs.append(int_attr("tool.glob.match_count", len(resp)))
        preview = resp[:20]
        attrs.append(str_attr("tool.glob.matches", "\n".join(str(p) for p in preview)))
    elif isinstance(resp, str):
        matches = [l for l in resp.strip().split("\n") if l]
        attrs.append(int_attr("tool.glob.match_count", len(matches)))
        attrs.append(str_attr("tool.glob.matches", "\n".join(matches[:20])))
    return attrs


def extract_grep_response(resp):
    attrs = []
    if isinstance(resp, list):
        attrs.append(int_attr("tool.grep.match_count", len(resp)))
        preview = resp[:20]
        attrs.append(str_attr("tool.grep.matches", "\n".join(str(m) for m in preview)))
    elif isinstance(resp, str):
        lines = [l for l in resp.strip().split("\n") if l]
        attrs.append(int_attr("tool.grep.match_count", len(lines)))
        attrs.append(str_attr("tool.grep.matches", "\n".join(lines[:20])))
    return attrs


def extract_agent_response(resp):
    attrs = []
    if isinstance(resp, dict):
        if "result" in resp:
            attrs.append(str_attr("tool.agent.result", resp["result"]))
        if "usage" in resp:
            usage = resp["usage"]
            if "total_tokens" in usage:
                attrs.append(int_attr("tool.agent.total_tokens", usage["total_tokens"]))
            if "tool_uses" in usage:
                attrs.append(int_attr("tool.agent.tool_uses", usage["tool_uses"]))
            if "duration_ms" in usage:
                attrs.append(int_attr("tool.agent.duration_ms", usage["duration_ms"]))
    elif isinstance(resp, str):
        attrs.append(str_attr("tool.agent.result", resp))
    return attrs


TOOL_RESPONSE_EXTRACTORS = {
    "Bash": extract_bash_response,
    "Read": extract_read_response,
    "Write": extract_write_edit_response,
    "Edit": extract_write_edit_response,
    "Glob": extract_glob_response,
    "Grep": extract_grep_response,
    "Agent": extract_agent_response,
}


def extract_tool_response_attrs(tool_name, resp):
    """Extract tool-specific response attributes, with generic fallback."""
    extractor = TOOL_RESPONSE_EXTRACTORS.get(tool_name)
    if extractor:
        return extractor(resp)
    if isinstance(resp, (dict, list)):
        return [str_attr("tool.response.body", json.dumps(resp))]
    return [str_attr("tool.response.body", resp)]


def compute_response_status(tool_name, resp):
    """Return (status_code, status_message, summary_string)."""
    if isinstance(resp, dict):
        if "exit_code" in resp:
            code = resp["exit_code"]
            if code != 0:
                return 2, f"exit_code={code}", f"ERROR (exit {code})"
            return 1, "", f"exit_code={code}"
        if "success" in resp:
            if not resp["success"]:
                return 2, "success=false", "ERROR"
            return 1, "", "success=true"
        if "error" in resp:
            return 2, truncate(resp["error"], 200), "ERROR"
        return 1, "", "ok"
    elif isinstance(resp, list):
        return 1, "", f"{len(resp)} results"
    elif isinstance(resp, str) and resp:
        return 1, "", truncate(resp, 60)
    return 1, "", "ok"


# -- Event Handlers ----------------------------------------------------

def handle_session_start(data):
    session_id = data.get("session_id", "")
    if not session_id:
        return
    trace_id = trace_id_from_session(session_id)
    span_id = random_span_id()
    start_ns = now_ns()
    cwd = data.get("cwd", "")
    write_state(f"session-{session_id}", {
        "trace_id": trace_id,
        "span_id": span_id,
        "start_ns": start_ns,
        "session_id": session_id,
        "cwd": cwd,
        "tool_count": 0,
        "turn_count": 0,
    })


def handle_session_end(data):
    session_id = data.get("session_id", "")
    if not session_id:
        return
    state = read_state(f"session-{session_id}")
    if not state:
        return
    end_ns = now_ns()
    dur = duration_ms(state["start_ns"], end_ns)
    send_span(
        trace_id=state["trace_id"],
        span_id=state["span_id"],
        name="session",
        start_ns=state["start_ns"],
        end_ns=end_ns,
        attributes=[
            str_attr("session.id", session_id),
            str_attr("session.cwd", state.get("cwd", "")),
            int_attr("session.duration_ms", dur),
            int_attr("session.turn_count", state.get("turn_count", 0)),
            int_attr("session.tool_count", state.get("tool_count", 0)),
        ],
        kind=2,
    )
    delete_state(f"session-{session_id}")
    delete_state(f"turn-{session_id}")
    counter_path = os.path.join(TRACE_DIR, f"turn-count-{session_id}")
    if os.path.exists(counter_path):
        os.remove(counter_path)


def handle_user_prompt(data):
    session_id = data.get("session_id", "")
    if not session_id:
        return
    session_state = read_state(f"session-{session_id}")
    trace_id = session_state["trace_id"] if session_state else trace_id_from_session(session_id)
    session_span_id = session_state["span_id"] if session_state else None
    span_id = random_span_id()
    start_ns = now_ns()
    prompt = data.get("user_prompt", "")
    prompt_preview = truncate(prompt, 100)
    turn_counter_file = os.path.join(TRACE_DIR, f"turn-count-{session_id}")
    turn_num = 1
    if os.path.exists(turn_counter_file):
        with open(turn_counter_file) as f:
            turn_num = int(f.read().strip()) + 1
    with open(turn_counter_file, "w") as f:
        f.write(str(turn_num))
    if session_state:
        session_state["turn_count"] = turn_num
        write_state(f"session-{session_id}", session_state)
    write_state(f"turn-{session_id}", {
        "trace_id": trace_id,
        "span_id": span_id,
        "parent_span_id": session_span_id,
        "start_ns": start_ns,
        "session_id": session_id,
        "turn_num": turn_num,
        "prompt_preview": prompt_preview,
        "prompt_full": truncate(prompt, MAX_ATTR_BYTES),
        "tool_count": 0,
    })


def handle_stop(data):
    session_id = data.get("session_id", "")
    if not session_id:
        return
    state = read_state(f"turn-{session_id}")
    if not state:
        return
    end_ns = now_ns()
    reason = data.get("reason", "")
    dur = duration_ms(state["start_ns"], end_ns)
    send_span(
        trace_id=state["trace_id"],
        span_id=state["span_id"],
        name=f"turn/{state['turn_num']}",
        start_ns=state["start_ns"],
        end_ns=end_ns,
        parent_span_id=state.get("parent_span_id"),
        attributes=[
            str_attr("session.id", session_id),
            int_attr("turn.number", state["turn_num"]),
            str_attr("turn.prompt_preview", state.get("prompt_preview", "")),
            str_attr("turn.prompt", state.get("prompt_full", "")),
            int_attr("turn.duration_ms", dur),
            int_attr("turn.tool_count", state.get("tool_count", 0)),
            str_attr("stop.reason", reason),
        ],
    )
    delete_state(f"turn-{session_id}")


def handle_subagent_stop(data):
    session_id = data.get("session_id", "")
    if not session_id:
        return
    turn_state = read_state(f"turn-{session_id}")
    trace_id = turn_state["trace_id"] if turn_state else trace_id_from_session(session_id)
    parent_span_id = turn_state["span_id"] if turn_state else None
    end_ns = now_ns()
    start_ns = str(int(end_ns) - 1_000_000)
    reason = data.get("reason", "")
    send_span(
        trace_id=trace_id,
        span_id=random_span_id(),
        name="subagent/complete",
        start_ns=start_ns,
        end_ns=end_ns,
        parent_span_id=parent_span_id,
        attributes=[
            str_attr("session.id", session_id),
            str_attr("subagent.reason", reason),
        ],
    )


def handle_pre_tool_use(data):
    tool_use_id = data.get("tool_use_id", "")
    session_id = data.get("session_id", "")
    if not tool_use_id:
        return
    turn_state = read_state(f"turn-{session_id}")
    trace_id = turn_state["trace_id"] if turn_state else trace_id_from_session(session_id)
    parent_span_id = turn_state["span_id"] if turn_state else None
    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input", {})
    if turn_state:
        turn_state["tool_count"] = turn_state.get("tool_count", 0) + 1
        write_state(f"turn-{session_id}", turn_state)
    session_state = read_state(f"session-{session_id}")
    if session_state:
        session_state["tool_count"] = session_state.get("tool_count", 0) + 1
        write_state(f"session-{session_id}", session_state)
    write_state(f"tool-{tool_use_id}", {
        "trace_id": trace_id,
        "span_id": random_span_id(),
        "parent_span_id": parent_span_id,
        "tool_name": tool_name,
        "tool_input": tool_input,
        "start_ns": now_ns(),
        "session_id": session_id,
    })


def handle_post_tool_use(data):
    tool_use_id = data.get("tool_use_id", "")
    if not tool_use_id:
        return
    state = read_state(f"tool-{tool_use_id}")
    if not state:
        return
    end_ns = now_ns()
    tool_name = state["tool_name"]
    resp = data.get("tool_response", {})
    dur = duration_ms(state["start_ns"], end_ns)
    status_code, status_message, status_summary = compute_response_status(tool_name, resp)
    attributes = [
        str_attr("tool.name", tool_name),
        str_attr("tool.use_id", tool_use_id),
        str_attr("session.id", state["session_id"]),
        int_attr("tool.duration_ms", dur),
        str_attr("tool.status_summary", status_summary),
    ]
    attributes.extend(extract_tool_input_attrs(tool_name, state.get("tool_input", {})))
    attributes.extend(extract_tool_response_attrs(tool_name, resp))
    events = None
    if status_code == 2:
        error_detail = ""
        if isinstance(resp, dict):
            error_detail = resp.get("stderr", "") or resp.get("error", "") or status_message
        events = [{
            "name": "exception",
            "timeUnixNano": end_ns,
            "attributes": [
                str_attr("exception.type", f"{tool_name}Error"),
                str_attr("exception.message", truncate(error_detail, MAX_ATTR_BYTES)),
            ],
        }]
    send_span(
        trace_id=state["trace_id"],
        span_id=state["span_id"],
        name=f"tool/{tool_name}",
        start_ns=state["start_ns"],
        end_ns=end_ns,
        parent_span_id=state.get("parent_span_id"),
        attributes=attributes,
        status_code=status_code,
        status_message=status_message,
        events=events,
    )
    delete_state(f"tool-{tool_use_id}")


def handle_dialog_decision(data):
    """Records a leaf span for a confirm-dialog.sh / confirm-dialog-multi.sh
    outcome (allow / deny / session-allow / timeout). The calling bash hook
    merges its own decision fields into the standard hook JSON before piping
    it here: dialog_hook, dialog_decision, dialog_category, dialog_gave_up.
    """
    session_id = data.get("session_id", "") or "no-session"
    session_state = read_state(f"session-{session_id}")
    trace_id = session_state["trace_id"] if session_state else trace_id_from_session(session_id)
    parent_span_id = session_state["span_id"] if session_state else None
    span_id = random_span_id()
    ts = now_ns()
    hook_name = data.get("dialog_hook", "unknown")
    send_span(
        trace_id=trace_id,
        span_id=span_id,
        name=f"dialog/{hook_name}",
        start_ns=ts,
        end_ns=ts,
        parent_span_id=parent_span_id,
        attributes=[
            str_attr("dialog.hook", hook_name),
            str_attr("dialog.decision", data.get("dialog_decision", "")),
            str_attr("dialog.category", truncate(data.get("dialog_category", ""), MAX_SUMMARY_BYTES)),
            str_attr("dialog.command", truncate(data.get("tool_input", {}).get("command", ""), MAX_ATTR_BYTES)),
            bool_attr("dialog.gave_up", bool(data.get("dialog_gave_up", False))),
            str_attr("dialog.cwd", data.get("cwd", "")),
        ],
    )


# -- Main --------------------------------------------------------------

HANDLERS = {
    "SessionStart": handle_session_start,
    "SessionEnd": handle_session_end,
    "UserPromptSubmit": handle_user_prompt,
    "Stop": handle_stop,
    "SubagentStop": handle_subagent_stop,
    "PreToolUse": handle_pre_tool_use,
    "PostToolUse": handle_post_tool_use,
    "DialogDecision": handle_dialog_decision,
}

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <event_type>", file=sys.stderr)
        sys.exit(1)

    event = sys.argv[1]
    handler = HANDLERS.get(event)
    if not handler:
        sys.exit(0)

    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, EOFError):
        data = {}

    handler(data)
