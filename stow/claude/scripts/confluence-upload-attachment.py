#!/usr/bin/env python3
"""confluence-upload-attachment.py

Upload a local file as a new attachment on a Confluence Cloud page, via the
REST API v1 attachment endpoint (v2 has no attachment-upload endpoint yet).

Why this exists:
Neither the Atlassian MCP tools nor `acli confluence page` (installed version
1.3.23-stable, `view` only) support attaching a file to a page. This fills
that gap with a direct API call, stdlib only (no `requests` dependency).

API reference:
    POST /wiki/rest/api/content/{id}/child/attachment
    https://developer.atlassian.com/cloud/confluence/rest/v1/api-group-content---attachments/
    Requires header X-Atlassian-Token: nocheck (XSRF protection on
    multipart/form-data endpoints).

Usage:
    export ATLASSIAN_EMAIL=you@example.com
    export ATLASSIAN_API_TOKEN=<token from id.atlassian.com/manage-profile/security/api-tokens>
    python3 confluence-upload-attachment.py \\
        --site example.atlassian.net \\
        --page-id 123456789 \\
        --file /path/to/diagram.png \\
        --comment "Architecture diagram"

Re-running with the same filename replaces the existing attachment (the v1
endpoint creates a new version of the same-named attachment rather than a
duplicate).
"""
from __future__ import annotations

import argparse
import base64
import json
import mimetypes
import os
import sys
import urllib.error
import urllib.request
import uuid


def basic_auth_header(email: str, token: str) -> str:
    raw = f"{email}:{token}".encode()
    return "Basic " + base64.b64encode(raw).decode()


def build_multipart_body(file_path: str, comment: str | None) -> tuple[bytes, str]:
    boundary = uuid.uuid4().hex
    filename = os.path.basename(file_path)
    content_type = mimetypes.guess_type(filename)[0] or "application/octet-stream"

    with open(file_path, "rb") as f:
        file_bytes = f.read()

    parts: list[bytes] = []

    def add_field(name: str, value: str) -> None:
        parts.append(
            (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="{name}"\r\n\r\n'
                f"{value}\r\n"
            ).encode()
        )

    parts.append(
        (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'
            f"Content-Type: {content_type}\r\n\r\n"
        ).encode()
        + file_bytes
        + b"\r\n"
    )
    add_field("minorEdit", "true")
    if comment:
        add_field("comment", comment)
    parts.append(f"--{boundary}--\r\n".encode())

    body = b"".join(parts)
    return body, boundary


def upload_attachment(
    site: str,
    page_id: str,
    auth: str,
    file_path: str,
    comment: str | None,
) -> dict:
    body, boundary = build_multipart_body(file_path, comment)
    url = f"https://{site}/wiki/rest/api/content/{page_id}/child/attachment"
    headers = {
        "Authorization": auth,
        "Accept": "application/json",
        "Content-Type": f"multipart/form-data; boundary={boundary}",
        "X-Atlassian-Token": "nocheck",
    }
    req = urllib.request.Request(url, method="POST", data=body, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"HTTP {e.code} on POST {url}\n")
        sys.stderr.write(f"  response body: {e.read().decode()[:1000]}\n")
        raise


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--site", required=True, help="e.g. example.atlassian.net")
    p.add_argument("--page-id", required=True)
    p.add_argument("--file", required=True, help="path to the local file to attach")
    p.add_argument("--comment", default=None, help="attachment description")
    args = p.parse_args()

    if not os.path.isfile(args.file):
        sys.stderr.write(f"ERROR: file not found: {args.file}\n")
        return 2

    email = os.environ.get("ATLASSIAN_EMAIL")
    token = os.environ.get("ATLASSIAN_API_TOKEN")
    if not email or not token:
        sys.stderr.write(
            "ERROR: set ATLASSIAN_EMAIL and ATLASSIAN_API_TOKEN env vars.\n"
            "Token: id.atlassian.com/manage-profile/security/api-tokens\n"
        )
        return 2

    auth = basic_auth_header(email, token)

    sys.stderr.write(
        f"uploading {args.file} ({os.path.getsize(args.file)} bytes) "
        f"to page {args.page_id} on {args.site}...\n"
    )
    result = upload_attachment(args.site, args.page_id, auth, args.file, args.comment)

    attachment = result["results"][0] if "results" in result else result
    download = attachment.get("_links", {}).get("download", "")
    sys.stderr.write(f"success: attachment id={attachment.get('id')}\n")
    print(
        json.dumps(
            {
                "ok": True,
                "id": attachment.get("id"),
                "download_path": download,
                "page_url": f"https://{args.site}/wiki/pages/viewpage.action?pageId={args.page_id}",
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
