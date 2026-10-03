"""Tests for $CLAUDE_CONFIG_DIR/scripts/confluence-reply.py.

Network and credentials are mocked with a fake session keyed by (method, URL).

Run: python3 -m pytest test_confluence_reply.py -v
"""
from __future__ import annotations

import importlib.util
import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parent.parent / "confluence-reply.py"
spec = importlib.util.spec_from_file_location("cr", SCRIPT)
cr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cr)

SITE = "https://example.atlassian.net"
BASE = f"{SITE}/wiki/api/v2"


class FakeResp:
    def __init__(self, payload=None, status=200):
        self._payload = payload or {}
        self.status_code = status
        self.ok = status < 400
        self.text = json.dumps(self._payload)

    def json(self):
        return self._payload

    def raise_for_status(self):
        if not self.ok:
            raise cr.requests.HTTPError(f"HTTP {self.status_code}")


class FakeSession:
    """Routes requests by (METHOD, url); records every call."""

    def __init__(self, routes):
        self.routes = routes
        self.calls = []

    def _do(self, method, url, params=None, json=None, **_):
        self.calls.append((method, url, params, json))
        r = self.routes.get((method, url))
        if r is None:
            return FakeResp({}, 404)
        return r if isinstance(r, FakeResp) else FakeResp(r)

    def get(self, url, params=None, **kw):
        return self._do("GET", url, params=params, **kw)

    def post(self, url, json=None, **kw):
        return self._do("POST", url, json=json, **kw)

    def put(self, url, json=None, **kw):
        return self._do("PUT", url, json=json, **kw)


def routes():
    return {
        ("GET", f"{BASE}/inline-comments/100"): {
            "id": "100",
            "resolutionStatus": "open",
            "version": {"number": 3},
            "body": {"storage": {"value": "<p>orig</p>"}},
        },
        ("GET", f"{BASE}/footer-comments/200"): {"id": "200", "version": {"number": 1}},
        ("POST", f"{BASE}/inline-comments"): {"id": "101", "_links": {"webui": "/x#comment-101"}},
        ("POST", f"{BASE}/footer-comments"): {"id": "201", "_links": {"webui": "/x#comment-201"}},
        ("PUT", f"{BASE}/inline-comments/100"): {"id": "100", "resolutionStatus": "resolved"},
        ("PUT", f"{BASE}/footer-comments/200"): {"id": "200"},
    }


def client(r=None):
    return cr.Client(FakeSession(r or routes()), BASE)


def writes(c):
    return [x for x in c.session.calls if x[0] in ("POST", "PUT")]


class TestToken(unittest.TestCase):
    def test_env_wins(self):
        with mock.patch.dict(cr.os.environ, {"CONFLUENCE_TOKEN": "t1"}), mock.patch.object(cr.subprocess, "run") as run:
            self.assertEqual(cr.get_token(), "t1")
            run.assert_not_called()

    def test_falls_back_to_op_cache(self):
        env = {k: v for k, v in cr.os.environ.items() if k != "CONFLUENCE_TOKEN"}
        done = mock.Mock(returncode=0, stdout="t2\n")
        with mock.patch.dict(cr.os.environ, env, clear=True), mock.patch.object(cr.subprocess, "run", return_value=done) as run:
            self.assertEqual(cr.get_token(), "t2")
            self.assertIn(cr.DEFAULT_OP_REF, run.call_args[0][0])

    def test_op_ref_env_override(self):
        env = {k: v for k, v in cr.os.environ.items() if k != "CONFLUENCE_TOKEN"}
        env["CONFLUENCE_OP_REF"] = "op://Vault/item/field"
        done = mock.Mock(returncode=0, stdout="t3\n")
        with mock.patch.dict(cr.os.environ, env, clear=True), mock.patch.object(cr.subprocess, "run", return_value=done) as run:
            self.assertEqual(cr.get_token(), "t3")
            self.assertIn("op://Vault/item/field", run.call_args[0][0])

    def test_op_cache_failure_exits(self):
        env = {k: v for k, v in cr.os.environ.items() if k != "CONFLUENCE_TOKEN"}
        done = mock.Mock(returncode=1, stdout="")
        with mock.patch.dict(cr.os.environ, env, clear=True), mock.patch.object(cr.subprocess, "run", return_value=done):
            with self.assertRaises(SystemExit):
                cr.get_token()


class TestApiBase(unittest.TestCase):
    def test_site(self):
        self.assertEqual(cr.api_base(None, SITE + "/wiki", gateway=False), BASE)

    def test_gateway(self):
        sess = FakeSession({("GET", f"{SITE}/_edge/tenant_info"): {"cloudId": "cid-1"}})
        self.assertEqual(cr.api_base(sess, SITE, gateway=True), "https://api.atlassian.com/ex/confluence/cid-1/wiki/api/v2")


class TestToStorage(unittest.TestCase):
    def test_paragraphs_and_escaping(self):
        out = cr.to_storage("a < b & c\n\nsecond para")
        self.assertEqual(out, "<p>a &lt; b &amp; c</p><p>second para</p>")

    def test_bullets(self):
        out = cr.to_storage("intro:\n- one\n- two")
        self.assertEqual(out, "<p>intro:</p><ul><li>one</li><li>two</li></ul>")

    def test_code_spans(self):
        self.assertEqual(cr.to_storage("use `--as` here"), "<p>use <code>--as</code> here</p>")

    def test_mention(self):
        out = cr.to_storage("@{abc:123-x}, thoughts?")
        self.assertIn('<ac:link><ri:user ri:account-id="abc:123-x" /></ac:link>', out)

    def test_soft_line_breaks_join(self):
        self.assertEqual(cr.to_storage("line one\nline two"), "<p>line one<br />line two</p>")


class TestDetectKind(unittest.TestCase):
    def test_inline(self):
        self.assertEqual(cr.detect_kind(client(), "100"), "inline")

    def test_footer(self):
        self.assertEqual(cr.detect_kind(client(), "200"), "footer")

    def test_missing(self):
        with self.assertRaises(SystemExit):
            cr.detect_kind(client(), "999")


class TestPlan(unittest.TestCase):
    def test_reply_inline_payload(self):
        m, url, payload = cr.plan_reply(client(), "100", "hi")
        self.assertEqual((m, url), ("POST", f"{BASE}/inline-comments"))
        self.assertEqual(payload, {"parentCommentId": "100", "body": {"representation": "storage", "value": "<p>hi</p>"}})

    def test_reply_footer_payload(self):
        _, url, payload = cr.plan_reply(client(), "200", "hi")
        self.assertEqual(url, f"{BASE}/footer-comments")
        self.assertNotIn("pageId", payload)

    def test_resolve_bumps_version_and_keeps_body(self):
        m, url, payload = cr.plan_resolve(client(), "100")
        self.assertEqual((m, url), ("PUT", f"{BASE}/inline-comments/100"))
        self.assertEqual(payload["version"]["number"], 4)
        self.assertTrue(payload["resolved"])
        self.assertEqual(payload["body"], {"representation": "storage", "value": "<p>orig</p>"})

    def test_resolve_footer_rejected(self):
        with self.assertRaises(SystemExit):
            cr.plan_resolve(client(), "200")

    def test_resolve_already_resolved_is_noop(self):
        r = routes()
        r[("GET", f"{BASE}/inline-comments/100")]["resolutionStatus"] = "resolved"
        self.assertIsNone(cr.plan_resolve(client(r), "100"))


class TestPlanEdit(unittest.TestCase):
    def test_edit_inline_replaces_body_and_bumps_version(self):
        m, url, payload = cr.plan_edit(client(), "100", "new text")
        self.assertEqual((m, url), ("PUT", f"{BASE}/inline-comments/100"))
        self.assertEqual(payload, {"version": {"number": 4}, "body": {"representation": "storage", "value": "<p>new text</p>"}})

    def test_edit_does_not_touch_resolution(self):
        _, _, payload = cr.plan_edit(client(), "100", "x")
        self.assertNotIn("resolved", payload)

    def test_edit_footer(self):
        m, url, payload = cr.plan_edit(client(), "200", "x")
        self.assertEqual(url, f"{BASE}/footer-comments/200")
        self.assertEqual(payload["version"]["number"], 2)

    def test_edit_missing_exits(self):
        with self.assertRaises(SystemExit):
            cr.plan_edit(client(), "999", "x")


class TestExecute(unittest.TestCase):
    def test_dry_run_sends_nothing(self):
        c = client()
        plan = cr.plan_reply(c, "100", "hi")
        with redirect_stdout(io.StringIO()) as buf:
            cr.execute(c, [plan], apply=False)
        self.assertEqual(writes(c), [])
        self.assertIn("DRY RUN", buf.getvalue())
        self.assertIn('"parentCommentId": "100"', buf.getvalue())

    def test_apply_sends(self):
        c = client()
        plans = [cr.plan_reply(c, "100", "hi"), cr.plan_resolve(c, "100")]
        with redirect_stdout(io.StringIO()) as buf:
            rc = cr.execute(c, plans, apply=True)
        self.assertEqual(rc, 0)
        self.assertEqual([w[0] for w in writes(c)], ["POST", "PUT"])
        self.assertIn("comment-101", buf.getvalue())

    def test_apply_stops_on_error(self):
        r = routes()
        r[("POST", f"{BASE}/inline-comments")] = FakeResp({"errors": ["nope"]}, 403)
        c = client(r)
        plans = [cr.plan_reply(c, "100", "hi"), cr.plan_resolve(c, "100")]
        with redirect_stdout(io.StringIO()):
            rc = cr.execute(c, plans, apply=True)
        self.assertEqual(rc, 1)
        self.assertEqual(len(writes(c)), 1)


class TestMain(unittest.TestCase):
    def run_main(self, argv, r=None):
        c = client(r)
        with mock.patch.object(cr, "make_client", return_value=c):
            with redirect_stdout(io.StringIO()) as buf:
                rc = cr.main(argv)
        return rc, buf.getvalue(), c

    def test_reply_defaults_to_dry_run(self):
        rc, out, c = self.run_main(["reply", "100", "--body", "hi"])
        self.assertEqual(rc, 0)
        self.assertEqual(writes(c), [])

    def test_reply_yes_posts(self):
        rc, _, c = self.run_main(["reply", "100", "--body", "hi", "--yes"])
        self.assertEqual(len(writes(c)), 1)

    def test_body_file(self):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
            f.write("from file")
        _, out, _ = self.run_main(["reply", "100", "--body-file", f.name])
        self.assertIn("from file", out)

    def test_batch_validates_all_before_sending(self):
        items = [{"action": "reply", "id": "100", "body": "ok"}, {"action": "resolve", "id": "200"}]
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(items, f)
        with self.assertRaises(SystemExit):
            self.run_main(["batch", f.name, "--yes"])

    def test_batch_happy_path(self):
        items = [{"action": "reply", "id": "100", "body": "ok"}, {"action": "resolve", "id": "100"}]
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(items, f)
        rc, _, c = self.run_main(["batch", f.name, "--yes"])
        self.assertEqual(rc, 0)
        self.assertEqual(len(writes(c)), 2)

    def test_edit_defaults_to_dry_run(self):
        rc, out, c = self.run_main(["edit", "100", "--body", "fixed"])
        self.assertEqual(rc, 0)
        self.assertEqual(writes(c), [])
        self.assertIn("<p>fixed</p>", out)

    def test_batch_edit(self):
        items = [{"action": "edit", "id": "100", "body": "fixed"}]
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(items, f)
        rc, _, c = self.run_main(["batch", f.name, "--yes"])
        self.assertEqual([w[0] for w in writes(c)], ["PUT"])

    def test_batch_edit_needs_body(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump([{"action": "edit", "id": "100"}], f)
        with self.assertRaises(SystemExit):
            self.run_main(["batch", f.name])

    def test_batch_unknown_action(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump([{"action": "delete", "id": "100"}], f)
        with self.assertRaises(SystemExit):
            self.run_main(["batch", f.name])


if __name__ == "__main__":
    unittest.main()
