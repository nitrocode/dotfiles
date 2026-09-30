#!/usr/bin/env python3
"""Reply to, edit, or resolve Confluence page comments. Dry-run by default; pass --yes to send.

Covers what confluence-cli can't: inline replies (its v1 path needs editor highlight
metadata), editing existing comments, and resolving threads. Use `confluence comments` for reads.
Replies are written as plain text and converted to storage format:
blank line = new paragraph, "- " lines = bullets, `code` = code span,
@{accountId} = user mention.

Usage:
  confluence-reply.py reply COMMENT_ID (--body TEXT | --body-file PATH) [--yes]
  confluence-reply.py edit COMMENT_ID (--body TEXT | --body-file PATH) [--yes]   # replace body; resolution untouched
  confluence-reply.py resolve COMMENT_ID [--yes]           # inline comments only
  confluence-reply.py batch FILE.json [--yes]              # [{"action": "reply"|"edit"|"resolve", "id": ..., "body": ...}]

Auth (basic, email + API token): CONFLUENCE_TOKEN (else op-cache.sh DEFAULT_OP_REF),
CONFLUENCE_USER, CONFLUENCE_SITE; --gateway for scoped tokens via api.atlassian.com.

Example:
  confluence-reply.py reply 5321752588 --body-file h1.txt          # preview
  confluence-reply.py reply 5321752588 --body-file h1.txt --yes    # send
"""
from __future__ import annotations

import argparse
import html
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import requests

DEFAULT_OP_REF = "op://Private/atlassian-token/credential"
DEFAULT_SITE = "https://example.atlassian.net"
DEFAULT_USER = "you@example.com"


class Client:
    """Thin wrapper holding an authenticated session and the v2 API base URL."""

    def __init__(self, session, base):
        self.session = session
        self.base = base.rstrip("/")
        self.root = self.base.split("/wiki/")[0]

    def get_json(self, url, params=None):
        """GET a URL and return parsed JSON, raising on HTTP errors."""
        r = self.session.get(url, params=params)
        r.raise_for_status()
        return r.json()


def get_token():
    """Return the API token from CONFLUENCE_TOKEN, else from op-cache.sh."""
    tok = os.environ.get("CONFLUENCE_TOKEN")
    if tok:
        return tok
    op_cache = Path(__file__).resolve().parent / "op-cache.sh"
    res = subprocess.run(
        ["bash", str(op_cache), "get", "atlassian-token", DEFAULT_OP_REF],
        stdout=subprocess.PIPE,
        text=True,
    )
    if res.returncode != 0 or not res.stdout.strip():
        sys.exit("confluence-reply: could not get token (set CONFLUENCE_TOKEN or fix op-cache)")
    return res.stdout.strip()


def api_base(session, site, gateway):
    """Return the v2 base URL for the site route or the api.atlassian.com gateway (scoped tokens)."""
    site = site.rstrip("/").removesuffix("/wiki")
    if not gateway:
        return f"{site}/wiki/api/v2"
    r = session.get(f"{site}/_edge/tenant_info")
    r.raise_for_status()
    return f"https://api.atlassian.com/ex/confluence/{r.json()['cloudId']}/wiki/api/v2"


def make_client(gateway):
    """Build an authenticated Client (basic auth, email + API token) from env and flags."""
    s = requests.Session()
    s.auth = (os.environ.get("CONFLUENCE_USER", DEFAULT_USER), get_token())
    return Client(s, api_base(s, os.environ.get("CONFLUENCE_SITE", DEFAULT_SITE), gateway))


def _inline(text):
    """Escape one line and apply code-span and mention markup."""
    out = html.escape(text, quote=False)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    return re.sub(
        r"@\{([^}]+)\}",
        lambda m: f'<ac:link><ri:user ri:account-id="{html.escape(m.group(1))}" /></ac:link>',
        out,
    )


def to_storage(text):
    """Convert simple plain text (paragraphs, '- ' bullets) to Confluence storage HTML."""
    parts = []
    for block in re.split(r"\n\s*\n", text.strip()):
        prose, bullets = [], []

        def flush_prose():
            if prose:
                parts.append("<p>" + "<br />".join(prose) + "</p>")
                prose.clear()

        def flush_bullets():
            if bullets:
                parts.append("<ul>" + "".join(f"<li>{b}</li>" for b in bullets) + "</ul>")
                bullets.clear()

        for line in block.splitlines():
            if line.lstrip().startswith("- "):
                flush_prose()
                bullets.append(_inline(line.lstrip()[2:].strip()))
            else:
                flush_bullets()
                prose.append(_inline(line.strip()))
        flush_prose()
        flush_bullets()
    return "".join(parts)


def detect_kind(client, comment_id):
    """Return 'inline' or 'footer' for a comment ID, exiting if neither exists."""
    for kind in ("inline", "footer"):
        r = client.session.get(f"{client.base}/{kind}-comments/{comment_id}")
        if r.ok:
            return kind
    sys.exit(f"confluence-reply: comment {comment_id} not found as inline or footer comment")


def plan_reply(client, comment_id, text):
    """Build (method, url, payload) for a reply to a comment."""
    kind = detect_kind(client, comment_id)
    payload = {"parentCommentId": comment_id, "body": {"representation": "storage", "value": to_storage(text)}}
    return ("POST", f"{client.base}/{kind}-comments", payload)


def plan_edit(client, comment_id, text):
    """Build (method, url, payload) to replace a comment's body. Leaves resolution state alone."""
    kind = detect_kind(client, comment_id)
    cur = client.get_json(f"{client.base}/{kind}-comments/{comment_id}")
    payload = {
        "version": {"number": cur["version"]["number"] + 1},
        "body": {"representation": "storage", "value": to_storage(text)},
    }
    return ("PUT", f"{client.base}/{kind}-comments/{comment_id}", payload)


def plan_resolve(client, comment_id):
    """Build (method, url, payload) to resolve an inline thread, or None if already resolved."""
    if detect_kind(client, comment_id) != "inline":
        sys.exit(f"confluence-reply: {comment_id} is a footer comment; only inline comments can be resolved")
    cur = client.get_json(f"{client.base}/inline-comments/{comment_id}", {"body-format": "storage"})
    if cur.get("resolutionStatus") == "resolved":
        print(f"# {comment_id} already resolved, skipping")
        return None
    payload = {
        "version": {"number": cur["version"]["number"] + 1},
        "body": {"representation": "storage", "value": cur.get("body", {}).get("storage", {}).get("value", "")},
        "resolved": True,
    }
    return ("PUT", f"{client.base}/inline-comments/{comment_id}", payload)


def execute(client, plans, apply):
    """Print each planned request; send them in order when apply is True. Stops on first error."""
    plans = [p for p in plans if p]
    for method, url, payload in plans:
        print(f"{'SEND' if apply else 'DRY RUN'}: {method} {url}")
        print(json.dumps(payload, indent=1))
        if not apply:
            continue
        r = getattr(client.session, method.lower())(url, json=payload)
        if not r.ok:
            print(f"ERROR {r.status_code}: {r.text[:500]}")
            return 1
        j = r.json()
        link = j.get("_links", {}).get("webui", "")
        print(f"OK #{j.get('id')} {client.root}/wiki{link}" if link else f"OK #{j.get('id')}")
    if not apply:
        print(f"\n{len(plans)} request(s) planned. Re-run with --yes to send.")
    return 0


def load_batch(path):
    """Read and validate a batch file of reply/resolve items."""
    items = json.loads(Path(path).read_text())
    for i, it in enumerate(items):
        if it.get("action") not in ("reply", "edit", "resolve") or not it.get("id"):
            sys.exit(f"confluence-reply: batch item {i} needs action reply|edit|resolve and an id")
        if it["action"] in ("reply", "edit") and not it.get("body"):
            sys.exit(f"confluence-reply: batch item {i} is a {it['action']} with no body")
    return items


def main(argv=None):
    """CLI entry point. Returns a process exit code."""
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--yes", action="store_true", help="actually send (default is dry run)")
    common.add_argument("--gateway", action="store_true", help="use api.atlassian.com (scoped tokens)")
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("reply", "edit"):
        sp = sub.add_parser(name, parents=[common])
        sp.add_argument("id")
        src = sp.add_mutually_exclusive_group(required=True)
        src.add_argument("--body")
        src.add_argument("--body-file")
    rs = sub.add_parser("resolve", parents=[common])
    rs.add_argument("id")
    bt = sub.add_parser("batch", parents=[common])
    bt.add_argument("file")
    args = ap.parse_args(argv)

    items = load_batch(args.file) if args.cmd == "batch" else None
    client = make_client(args.gateway)

    # Plan everything before sending anything, so a bad item aborts the whole run.
    planners = {"reply": plan_reply, "edit": plan_edit}
    if args.cmd in planners:
        text = args.body if args.body is not None else Path(args.body_file).read_text()
        plans = [planners[args.cmd](client, args.id, text)]
    elif args.cmd == "resolve":
        plans = [plan_resolve(client, args.id)]
    else:
        plans = [
            planners[it["action"]](client, it["id"], it["body"]) if it["action"] in planners
            else plan_resolve(client, it["id"])
            for it in items
        ]
    return execute(client, plans, apply=args.yes)


if __name__ == "__main__":
    sys.exit(main())
