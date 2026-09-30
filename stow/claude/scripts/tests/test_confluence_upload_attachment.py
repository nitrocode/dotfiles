"""Tests for $CLAUDE_CONFIG_DIR/scripts/confluence-upload-attachment.py.

Network and credentials are mocked; tests verify multipart body shape,
CLI plumbing, and error handling for missing file/creds.

Run: python3 -m pytest test_confluence_upload_attachment.py -v
Or:  python3 test_confluence_upload_attachment.py
"""
from __future__ import annotations

import base64
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parent.parent / "confluence-upload-attachment.py"

spec = importlib.util.spec_from_file_location("cua", SCRIPT)
cua = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cua)


class TestBasicAuth(unittest.TestCase):
    def test_basic_auth_header_shape(self) -> None:
        h = cua.basic_auth_header("a@b.com", "tok")
        self.assertTrue(h.startswith("Basic "))
        decoded = base64.b64decode(h[len("Basic ") :]).decode()
        self.assertEqual(decoded, "a@b.com:tok")


class TestMultipartBody(unittest.TestCase):
    def _write_temp_file(self, content: bytes, suffix: str) -> str:
        f = tempfile.NamedTemporaryFile(suffix=suffix, delete=False)
        f.write(content)
        f.close()
        return f.name

    def test_body_contains_filename_and_bytes(self) -> None:
        path = self._write_temp_file(b"\x89PNGfakepngbytes", ".png")
        try:
            body, boundary = cua.build_multipart_body(path, comment=None)
            self.assertIn(boundary.encode(), body)
            self.assertIn(os.path.basename(path).encode(), body)
            self.assertIn(b"\x89PNGfakepngbytes", body)
            self.assertIn(b'name="minorEdit"', body)
            self.assertNotIn(b'name="comment"', body)
        finally:
            os.unlink(path)

    def test_body_includes_comment_when_given(self) -> None:
        path = self._write_temp_file(b"data", ".png")
        try:
            body, _ = cua.build_multipart_body(path, comment="a diagram")
            self.assertIn(b'name="comment"', body)
            self.assertIn(b"a diagram", body)
        finally:
            os.unlink(path)

    def test_content_type_guessed_from_extension(self) -> None:
        path = self._write_temp_file(b"data", ".png")
        try:
            body, _ = cua.build_multipart_body(path, comment=None)
            self.assertIn(b"Content-Type: image/png", body)
        finally:
            os.unlink(path)


class TestUploadRequest(unittest.TestCase):
    def test_upload_sets_xsrf_header_and_posts(self) -> None:
        path = tempfile.NamedTemporaryFile(suffix=".png", delete=False)
        path.write(b"data")
        path.close()
        try:
            captured = {}

            class FakeResponse:
                def __enter__(self):
                    return self

                def __exit__(self, *a):
                    return False

                def read(self):
                    return json.dumps({"results": [{"id": "att123", "_links": {"download": "/x"}}]}).encode()

            def fake_urlopen(req, timeout=60):
                captured["method"] = req.get_method()
                captured["headers"] = dict(req.header_items())
                captured["url"] = req.full_url
                return FakeResponse()

            with mock.patch.object(cua.urllib.request, "urlopen", side_effect=fake_urlopen):
                result = cua.upload_attachment(
                    "example.atlassian.net", "5579898921", "Basic xxx", path.name, "a comment"
                )

            self.assertEqual(captured["method"], "POST")
            self.assertEqual(
                captured["headers"].get("X-atlassian-token")
                or captured["headers"].get("X-Atlassian-Token"),
                "nocheck",
            )
            self.assertIn("child/attachment", captured["url"])
            self.assertEqual(result["results"][0]["id"], "att123")
        finally:
            os.unlink(path.name)


class TestMissingFile(unittest.TestCase):
    def test_exits_with_2_when_file_missing(self) -> None:
        env = dict(os.environ)
        env["ATLASSIAN_EMAIL"] = "a@b.com"
        env["ATLASSIAN_API_TOKEN"] = "tok"
        r = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--site",
                "example.atlassian.net",
                "--page-id",
                "1",
                "--file",
                "/tmp/does-not-exist-12345.png",
            ],
            env=env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(r.returncode, 2)
        self.assertIn("not found", r.stderr.lower())


class TestMissingCreds(unittest.TestCase):
    def test_exits_with_2_when_env_missing(self) -> None:
        f = tempfile.NamedTemporaryFile(suffix=".png", delete=False)
        f.write(b"data")
        f.close()
        try:
            env = {
                k: v
                for k, v in os.environ.items()
                if k not in ("ATLASSIAN_EMAIL", "ATLASSIAN_API_TOKEN")
            }
            r = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--site",
                    "example.atlassian.net",
                    "--page-id",
                    "1",
                    "--file",
                    f.name,
                ],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(r.returncode, 2)
            self.assertIn("ATLASSIAN_EMAIL", r.stderr)
        finally:
            os.unlink(f.name)


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
