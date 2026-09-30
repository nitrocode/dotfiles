"""Tests for otel-trace.py's DialogDecision handler.

Loads the hyphenated script via importlib (can't be imported as a normal
module name) and monkeypatches send_span so no real network call happens.

Run: pytest ~/.claude/hooks/tests/test_otel_trace.py
"""
import importlib.util
import os
import sys

import pytest

SCRIPT_PATH = os.path.join(os.path.dirname(__file__), "..", "otel-trace.py")

spec = importlib.util.spec_from_file_location("otel_trace", SCRIPT_PATH)
otel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(otel)


@pytest.fixture
def captured_spans(monkeypatch):
    calls = []

    def fake_send_span(**kwargs):
        calls.append(kwargs)

    monkeypatch.setattr(otel, "send_span", fake_send_span)
    return calls


def test_dialog_decision_no_session_state(captured_spans):
    data = {
        "session_id": "test-otel-dialog-no-state",
        "cwd": "/tmp/repo",
        "tool_input": {"command": "terraform apply"},
        "dialog_hook": "confirm-dialog-multi.sh",
        "dialog_decision": "deny",
        "dialog_category": "Destroys AWS resources",
        "dialog_gave_up": False,
    }
    otel.handle_dialog_decision(data)

    assert len(captured_spans) == 1
    span = captured_spans[0]
    assert span["name"] == "dialog/confirm-dialog-multi.sh"
    assert span["parent_span_id"] is None

    attrs = {a["key"]: a["value"] for a in span["attributes"]}
    assert attrs["dialog.hook"]["stringValue"] == "confirm-dialog-multi.sh"
    assert attrs["dialog.decision"]["stringValue"] == "deny"
    assert attrs["dialog.category"]["stringValue"] == "Destroys AWS resources"
    assert attrs["dialog.command"]["stringValue"] == "terraform apply"
    assert attrs["dialog.gave_up"]["boolValue"] is False
    assert attrs["dialog.cwd"]["stringValue"] == "/tmp/repo"


def test_dialog_decision_with_session_state(captured_spans, tmp_path, monkeypatch):
    monkeypatch.setattr(otel, "TRACE_DIR", str(tmp_path))
    session_id = "test-otel-dialog-with-state"
    otel.write_state(f"session-{session_id}", {
        "trace_id": "abc123",
        "span_id": "def456",
    })

    data = {
        "session_id": session_id,
        "cwd": "/tmp/repo",
        "tool_input": {"command": "rm -rf /tmp/somewhere"},
        "dialog_hook": "confirm-dialog.sh",
        "dialog_decision": "allow",
        "dialog_category": "rm -r targeting paths outside cwd and home:",
        "dialog_gave_up": False,
    }
    otel.handle_dialog_decision(data)

    otel.delete_state(f"session-{session_id}")

    assert len(captured_spans) == 1
    span = captured_spans[0]
    assert span["trace_id"] == "abc123"
    assert span["parent_span_id"] == "def456"


def test_dialog_decision_gave_up_true(captured_spans):
    data = {
        "session_id": "test-otel-dialog-gaveup",
        "cwd": "/tmp/repo",
        "tool_input": {"command": "kubectl delete pod foo"},
        "dialog_hook": "confirm-dialog-multi.sh",
        "dialog_decision": "deny",
        "dialog_category": "Deletes Kubernetes resources",
        "dialog_gave_up": True,
    }
    otel.handle_dialog_decision(data)

    attrs = {a["key"]: a["value"] for a in captured_spans[0]["attributes"]}
    assert attrs["dialog.gave_up"]["boolValue"] is True


def test_dialog_decision_missing_session_id_falls_back(captured_spans):
    data = {
        "cwd": "/tmp/repo",
        "tool_input": {"command": "terraform destroy"},
        "dialog_hook": "confirm-dialog-multi.sh",
        "dialog_decision": "deny",
        "dialog_category": "Modifies or destroys Terraform-managed infrastructure",
    }
    # Should not raise despite no session_id, and dialog.gave_up defaults false.
    otel.handle_dialog_decision(data)
    attrs = {a["key"]: a["value"] for a in captured_spans[0]["attributes"]}
    assert attrs["dialog.gave_up"]["boolValue"] is False


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
