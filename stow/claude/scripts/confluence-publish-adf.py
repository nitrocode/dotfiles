#!/usr/bin/env python3
"""confluence-publish-adf.py

Publish an ADF JSON file to a Confluence Cloud page via the REST API v2.

Why this exists:
The Atlassian MCP `updateConfluencePage` tool accepts `contentFormat:"adf"`
but the body parameter has to be inlined as a string, which fails for pages
above ~25K tokens (Claude tool-call cap). It also doesn't expose
`minorEdit` to suppress watcher notifications.

This script:
1. Reads ADF JSON from a file
2. GETs the current page version
3. PUTs the update with body + (version+1) + minorEdit (default True)
4. Authenticates via Basic auth using ATLASSIAN_EMAIL + ATLASSIAN_API_TOKEN

Usage:
    export ATLASSIAN_EMAIL=you@example.com
    export ATLASSIAN_API_TOKEN=<token from id.atlassian.com/manage-profile/security/api-tokens>
    python3 confluence-publish-adf.py \\
        --site example.atlassian.net \\
        --page-id 5216174223 \\
        --adf /tmp/liftoff_v23_body.adf.json \\
        --message "v23 (2026-05-27): meta-rubric removal + tighter TOC via marklassian /toc macro" \\
        --title "Security Review - Liftoff SDK"

Add --notify to allow watcher notifications (default is silent / minor edit).

Confluence v2 PUT /wiki/api/v2/pages/{id} body schema:
    https://developer.atlassian.com/cloud/confluence/rest/v2/api-group-page/#api-pages-id-put
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request


def basic_auth_header(email: str, token: str) -> str:
    raw = f"{email}:{token}".encode()
    return "Basic " + base64.b64encode(raw).decode()


def http_request(method: str, url: str, headers: dict, body: bytes | None) -> dict:
    req = urllib.request.Request(url, method=method, data=body, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"HTTP {e.code} on {method} {url}\n")
        sys.stderr.write(f"  response body: {e.read().decode()[:1000]}\n")
        raise


def get_page(site: str, page_id: str, auth: str) -> dict:
    url = f"https://{site}/wiki/api/v2/pages/{page_id}?body-format=storage"
    return http_request("GET", url, {"Authorization": auth, "Accept": "application/json"}, None)


def update_page(
    site: str,
    page_id: str,
    auth: str,
    title: str,
    new_version: int,
    adf_body_str: str,
    message: str,
    notify: bool,
) -> dict:
    url = f"https://{site}/wiki/api/v2/pages/{page_id}"
    payload = {
        "id": page_id,
        "status": "current",
        "title": title,
        "body": {
            "representation": "atlas_doc_format",
            "value": adf_body_str,
        },
        "version": {
            "number": new_version,
            "message": message,
            "minorEdit": not notify,
        },
    }
    body = json.dumps(payload).encode()
    headers = {
        "Authorization": auth,
        "Accept": "application/json",
        "Content-Type": "application/json",
    }
    return http_request("PUT", url, headers, body)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--site", required=True, help="e.g. example.atlassian.net")
    p.add_argument("--page-id", required=True)
    p.add_argument("--adf", required=True, help="path to ADF JSON file")
    p.add_argument("--message", required=True, help="version message")
    p.add_argument(
        "--title",
        default=None,
        help="page title; if omitted, keeps the existing title",
    )
    p.add_argument(
        "--notify",
        action="store_true",
        help="allow watcher notifications (default: minor edit, silent)",
    )
    args = p.parse_args()

    email = os.environ.get("ATLASSIAN_EMAIL")
    token = os.environ.get("ATLASSIAN_API_TOKEN")
    if not email or not token:
        sys.stderr.write(
            "ERROR: set ATLASSIAN_EMAIL and ATLASSIAN_API_TOKEN env vars.\n"
            "Token: id.atlassian.com/manage-profile/security/api-tokens\n"
        )
        return 2

    with open(args.adf, "r", encoding="utf-8") as f:
        adf_obj = json.load(f)
    adf_body_str = json.dumps(adf_obj, separators=(",", ":"))

    auth = basic_auth_header(email, token)

    sys.stderr.write(f"fetching current version of page {args.page_id}...\n")
    current = get_page(args.site, args.page_id, auth)
    current_version = current["version"]["number"]
    current_title = current["title"]
    new_title = args.title or current_title
    new_version = current_version + 1

    sys.stderr.write(
        f"current v{current_version} title={current_title!r}; "
        f"pushing v{new_version} title={new_title!r}, "
        f"adf={len(adf_body_str)} chars, "
        f"minorEdit={not args.notify}\n"
    )

    result = update_page(
        args.site,
        args.page_id,
        auth,
        new_title,
        new_version,
        adf_body_str,
        args.message,
        args.notify,
    )

    sys.stderr.write(
        f"success: v{result['version']['number']} created at "
        f"{result['version']['createdAt']}\n"
    )
    sys.stderr.write(
        f"page URL: https://{args.site}/wiki{result['_links']['webui']}\n"
    )
    print(json.dumps({"version": result["version"]["number"], "ok": True}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
