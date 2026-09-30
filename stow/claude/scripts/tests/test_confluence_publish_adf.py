"""Tests for $CLAUDE_CONFIG_DIR/scripts/confluence-publish-adf.py.

Network and credentials are mocked; tests verify CLI plumbing, payload
shape, and the minorEdit/notify mapping.

Run: python3 -m pytest test_confluence_publish_adf.py -v
Or:  python3 test_confluence_publish_adf.py
"""
from __future__ import annotations

import base64
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parent.parent / "confluence-publish-adf.py"

# Load the script as a module so we can test internals directly
spec = importlib.util.spec_from_file_location("cpa", SCRIPT)
cpa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cpa)


class TestBasicAuth(unittest.TestCase):
    def test_basic_auth_header_shape(self) -> None:
        h = cpa.basic_auth_header("a@b.com", "tok")
        self.assertTrue(h.startswith("Basic "))
        decoded = base64.b64decode(h[len("Basic ") :]).decode()
        self.assertEqual(decoded, "a@b.com:tok")


class TestUpdatePayload(unittest.TestCase):
    def _captured_request(self, notify: bool):
        captured = {}

        def fake_http(method, url, headers, body):
            captured["method"] = method
            captured["url"] = url
            captured["headers"] = headers
            captured["body"] = json.loads(body.decode())
            return {
                "version": {"number": 99, "createdAt": "2026-01-01T00:00:00Z"},
                "_links": {"webui": "/x"},
            }

        with mock.patch.object(cpa, "http_request", side_effect=fake_http):
            cpa.update_page(
                site="example.atlassian.net",
                page_id="123",
                auth="Basic xxx",
                title="My Title",
                new_version=42,
                adf_body_str='{"version":1,"type":"doc","content":[]}',
                message="msg",
                notify=notify,
            )
        return captured

    def test_minor_edit_when_no_notify(self) -> None:
        c = self._captured_request(notify=False)
        self.assertEqual(c["method"], "PUT")
        self.assertEqual(c["body"]["version"]["minorEdit"], True)
        self.assertEqual(
            c["body"]["body"]["representation"], "atlas_doc_format"
        )
        self.assertEqual(c["body"]["version"]["number"], 42)

    def test_notify_flag_sets_minor_edit_false(self) -> None:
        c = self._captured_request(notify=True)
        self.assertEqual(c["body"]["version"]["minorEdit"], False)


class TestMissingCreds(unittest.TestCase):
    def test_exits_with_2_when_env_missing(self) -> None:
        with tempfile.NamedTemporaryFile(suffix=".json", delete=False, mode="w") as f:
            json.dump({"version": 1, "type": "doc", "content": []}, f)
            path = f.name
        try:
            env = {k: v for k, v in os.environ.items() if k not in ("ATLASSIAN_EMAIL", "ATLASSIAN_API_TOKEN")}
            r = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--site",
                    "example.atlassian.net",
                    "--page-id",
                    "1",
                    "--adf",
                    path,
                    "--message",
                    "x",
                ],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(r.returncode, 2)
            self.assertIn("ATLASSIAN_EMAIL", r.stderr)
        finally:
            os.unlink(path)


class TestArgParsing(unittest.TestCase):
    def test_missing_required_args(self) -> None:
        r = subprocess.run(
            [sys.executable, str(SCRIPT)],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("required", r.stderr.lower())


if __name__ == "__main__":
    unittest.main()
