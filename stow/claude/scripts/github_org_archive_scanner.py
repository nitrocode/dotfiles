#!/usr/bin/env -S uv run --script
# visibility: public
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "httpx>=0.27",
#   "rich>=13",
# ]
# ///
"""GitHub org archive-candidate scanner. Report-only, no mutations.

Identifies inactive repos in a GitHub org that are likely safe to archive
based on push/update recency, clone traffic, cross-references, and README signals.

Usage:
    GITHUB_TOKEN=<token> ./github_org_archive_scanner.py --org <org-name>

Defaults to `$GITHUB_ORG` env var if --org is omitted.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import csv as _csv_mod
import json
import os
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import httpx
from rich.console import Console

VERSION = "0.2.0"
console = Console()
GITHUB_API = "https://api.github.com"


@dataclass
class RepoSignals:
    name: str
    archived: bool = False
    fork: bool = False
    pushed_at: datetime | None = None
    updated_at: datetime | None = None
    size_kb: int = 0
    language: str | None = None
    stars: int = 0
    forks: int = 0
    open_issues: int = 0
    open_prs: int = 0
    clones_14d: int | None = None
    unique_cloners_14d: int | None = None
    internal_refs: int | None = None
    internal_ref_files: list[str] = field(default_factory=list)
    readme_keywords: list[str] = field(default_factory=list)
    codeowners_valid: bool | None = None
    last_release_at: datetime | None = None
    last_actions_at: datetime | None = None
    last_default_commit_at: datetime | None = None
    confidence: int = 0


@dataclass
class Config:
    org: str
    pushed_threshold_years: int = 3
    updated_threshold_years: int = 1
    output_dir: Path = field(default_factory=lambda: Path("."))
    concurrency: int = 30
    code_search_rate_per_min: int = 30
    max_clones: int = 10_000
    max_unique_cloners: int = 1
    max_internal_refs: int = 1_000_000  # effectively off; filter 6 is informational
    cache_dir: Path | None = None
    skip_refs: bool = False


def parse_args(argv: list[str] | None = None) -> Config:
    p = argparse.ArgumentParser(description="GitHub org archive-candidate scanner")
    p.add_argument(
        "--org",
        default=os.environ.get("GITHUB_ORG", ""),
        help="GitHub org to scan (or set $GITHUB_ORG). Required.",
    )
    p.add_argument("--pushed-years", type=int, default=3)
    p.add_argument("--updated-years", type=int, default=1)
    p.add_argument("--output-dir", type=Path, default=Path("."))
    p.add_argument("--concurrency", type=int, default=30)
    p.add_argument(
        "--max-clones",
        type=int,
        default=10_000,
        help="Max total clones in last 14d to still flag as candidate (default 10000, generous to allow automation)",
    )
    p.add_argument(
        "--max-unique-cloners",
        type=int,
        default=1,
        help="Max unique cloners in last 14d to flag (default 1, allows a single automation source)",
    )
    p.add_argument(
        "--max-internal-refs",
        type=int,
        default=1_000_000,
        help="Max cross-repo references to still flag (default unlimited; filter 6 informational)",
    )
    p.add_argument(
        "--cache-dir",
        type=Path,
        default=None,
        help="Directory to cache per-stage outputs; reruns reuse cached data and skip API calls",
    )
    p.add_argument(
        "--skip-refs",
        action="store_true",
        help="Skip stage 3 (cross-reference search). Saves ~7+ min; loses internal_refs data.",
    )
    ns = p.parse_args(argv)
    if not ns.org:
        p.error("--org is required (or set GITHUB_ORG env var)")
    return Config(
        org=ns.org,
        pushed_threshold_years=ns.pushed_years,
        updated_threshold_years=ns.updated_years,
        output_dir=ns.output_dir,
        concurrency=ns.concurrency,
        max_clones=ns.max_clones,
        max_unique_cloners=ns.max_unique_cloners,
        max_internal_refs=ns.max_internal_refs,
        cache_dir=ns.cache_dir,
        skip_refs=ns.skip_refs,
    )


class GitHubClient:
    def __init__(self, *, org: str, rate_limit_buffer: int = 100, timeout: float = 30.0):
        token = os.environ.get("GITHUB_TOKEN")
        if not token:
            raise RuntimeError("GITHUB_TOKEN not set in environment")
        self._token = token
        self._client = httpx.AsyncClient(
            base_url=GITHUB_API,
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": f"{org}-archive-scanner",
            },
            timeout=timeout,
        )
        self._rate_limit_buffer = rate_limit_buffer
        self.paused_count = 0

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        await self._client.aclose()

    async def get(self, path: str, **kwargs: Any) -> httpx.Response:
        r: httpx.Response | None = None
        last_exc: Exception | None = None
        for attempt in range(3):
            try:
                r = await self._client.get(path, **kwargs)
            except httpx.RequestError as e:
                # Transient connection / DNS / timeout. Back off and retry.
                last_exc = e
                self.paused_count += 1
                await asyncio.sleep(2 ** attempt)
                continue
            is_rate_limited = r.status_code == 429 or (
                r.status_code == 403 and "rate limit" in r.text.lower()
            )
            if is_rate_limited:
                retry_after = int(r.headers.get("retry-after", "30"))
                self.paused_count += 1
                await asyncio.sleep(min(retry_after, 60))
                continue
            self._maybe_pause(r)
            return r
        if last_exc is not None:
            raise last_exc
        assert r is not None
        return r

    def _maybe_pause(self, r: httpx.Response) -> None:
        remaining = r.headers.get("x-ratelimit-remaining")
        reset = r.headers.get("x-ratelimit-reset")
        if remaining is None or reset is None:
            return
        if int(remaining) < self._rate_limit_buffer:
            self.paused_count += 1


def _parse_iso(s: str | None) -> datetime | None:
    if not s:
        return None
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def _signals_to_jsonable(repos: list[RepoSignals]) -> list[dict]:
    """Serialize RepoSignals to a JSON-safe list, preserving all enriched fields."""
    def _iso(d: datetime | None) -> str | None:
        return d.isoformat() if d else None

    return [
        {
            "name": r.name,
            "archived": r.archived,
            "fork": r.fork,
            "pushed_at": _iso(r.pushed_at),
            "updated_at": _iso(r.updated_at),
            "size_kb": r.size_kb,
            "language": r.language,
            "stars": r.stars,
            "forks": r.forks,
            "open_issues": r.open_issues,
            "open_prs": r.open_prs,
            "clones_14d": r.clones_14d,
            "unique_cloners_14d": r.unique_cloners_14d,
            "internal_refs": r.internal_refs,
            "internal_ref_files": r.internal_ref_files,
            "readme_keywords": r.readme_keywords,
            "codeowners_valid": r.codeowners_valid,
            "last_release_at": _iso(r.last_release_at),
            "last_actions_at": _iso(r.last_actions_at),
            "last_default_commit_at": _iso(r.last_default_commit_at),
        }
        for r in repos
    ]


def _signals_from_jsonable(data: list[dict]) -> list[RepoSignals]:
    return [
        RepoSignals(
            name=d["name"],
            archived=d.get("archived", False),
            fork=d.get("fork", False),
            pushed_at=_parse_iso(d.get("pushed_at")),
            updated_at=_parse_iso(d.get("updated_at")),
            size_kb=d.get("size_kb", 0),
            language=d.get("language"),
            stars=d.get("stars", 0),
            forks=d.get("forks", 0),
            open_issues=d.get("open_issues", 0),
            open_prs=d.get("open_prs", 0),
            clones_14d=d.get("clones_14d"),
            unique_cloners_14d=d.get("unique_cloners_14d"),
            internal_refs=d.get("internal_refs"),
            internal_ref_files=d.get("internal_ref_files", []) or [],
            readme_keywords=d.get("readme_keywords", []) or [],
            codeowners_valid=d.get("codeowners_valid"),
            last_release_at=_parse_iso(d.get("last_release_at")),
            last_actions_at=_parse_iso(d.get("last_actions_at")),
            last_default_commit_at=_parse_iso(d.get("last_default_commit_at")),
        )
        for d in data
    ]


def _cache_load(cache_dir: Path | None, name: str) -> list[RepoSignals] | None:
    if cache_dir is None:
        return None
    path = cache_dir / f"{name}.json"
    if not path.exists():
        return None
    return _signals_from_jsonable(json.loads(path.read_text()))


def _cache_save(cache_dir: Path | None, name: str, repos: list[RepoSignals]) -> None:
    if cache_dir is None:
        return
    cache_dir.mkdir(parents=True, exist_ok=True)
    path = cache_dir / f"{name}.json"
    path.write_text(json.dumps(_signals_to_jsonable(repos), indent=2))


def _to_signals(raw: dict) -> RepoSignals:
    """Parse a GitHub REST API repo object into RepoSignals."""
    return RepoSignals(
        name=raw["name"],
        archived=raw.get("archived", False),
        fork=raw.get("fork", False),
        pushed_at=_parse_iso(raw.get("pushed_at")),
        updated_at=_parse_iso(raw.get("updated_at")),
        size_kb=raw.get("size", 0),
        language=raw.get("language"),
        stars=raw.get("stargazers_count", 0),
        forks=raw.get("forks_count", 0),
        open_issues=raw.get("open_issues_count", 0),
        open_prs=0,  # REST endpoint folds PRs into open_issues_count; not separable cheaply
    )


def filter_stage1(raw_repos: list[dict], cfg: Config) -> list[RepoSignals]:
    """Filter on cheap REST-API fields: drop archived, forks, and recently-updated.

    Note: `pushed_at` is intentionally NOT used here. After the GHE-to-EMU
    migration on 2024-12-14 every repo's `pushed_at` was reset to that date,
    making it unreliable as an activity signal. Actual last-commit-on-default
    is fetched per-repo in apply_default_commit_age_filter.
    """
    now = datetime.now(timezone.utc)
    updated_cutoff = now - timedelta(days=365 * cfg.updated_threshold_years)
    survivors: list[RepoSignals] = []
    for raw in raw_repos:
        sig = _to_signals(raw)
        if sig.archived or sig.fork:
            continue
        if sig.updated_at is None or sig.updated_at > updated_cutoff:
            continue
        survivors.append(sig)
    return survivors


async def fetch_last_default_commit(
    client: GitHubClient, org: str, repo: str
) -> datetime | None:
    """Return the committer date of the latest commit on the default branch.

    Uses `/repos/{owner}/{repo}/commits?per_page=1` which returns the most
    recent commit reachable from the default branch.
    """
    r = await client.get(f"/repos/{org}/{repo}/commits", params={"per_page": 1})
    if r.status_code != 200:
        return None
    commits = r.json()
    if not commits:
        return None
    return _parse_iso(
        (commits[0].get("commit") or {}).get("committer", {}).get("date")
    )


async def apply_default_commit_age_filter(
    client: GitHubClient,
    org: str,
    repos: list[RepoSignals],
    threshold_years: int,
    concurrency: int = 30,
) -> list[RepoSignals]:
    """Fetch last default-branch commit per repo, keep those older than threshold."""
    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(days=365 * threshold_years)
    sem = asyncio.Semaphore(concurrency)

    async def _fetch(repo: RepoSignals) -> RepoSignals:
        async with sem:
            try:
                repo.last_default_commit_at = await fetch_last_default_commit(
                    client, org, repo.name
                )
            except (httpx.HTTPStatusError, httpx.RequestError):
                repo.last_default_commit_at = None
            return repo

    enriched = await asyncio.gather(*(_fetch(r) for r in repos))
    return [
        r for r in enriched
        if r.last_default_commit_at is not None and r.last_default_commit_at < cutoff
    ]


def discover_repos(cfg: Config) -> list[RepoSignals]:
    """Walk the org's repos via REST API, sorted by pushed_at ascending.

    Stops early once we encounter a repo pushed more recently than the cutoff,
    since the remaining repos in the asc-sorted list will all be even more recent.
    """
    cmd = [
        "gh", "api", "--paginate",
        f"/orgs/{cfg.org}/repos?sort=pushed&direction=asc&per_page=100",
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"gh api failed (exit {result.returncode}): "
            f"{result.stderr.strip() or '<no stderr>'}"
        )
    # `gh api --paginate` concatenates page results; with this endpoint
    # each page is a JSON array, so the combined stream is array-of-array.
    # gh actually flattens it into a single array — confirmed by gh docs.
    raw = json.loads(result.stdout)
    return filter_stage1(raw, cfg)


async def fetch_clone_traffic(
    client: GitHubClient, org: str, repo: str
) -> tuple[int, int]:
    r = await client.get(f"/repos/{org}/{repo}/traffic/clones")
    r.raise_for_status()
    data = r.json()
    return data.get("count", 0), data.get("uniques", 0)


async def apply_clone_filter(
    client: GitHubClient,
    org: str,
    repos: list[RepoSignals],
    concurrency: int = 30,
    max_clones: int = 10_000,
    max_unique_cloners: int = 1,
) -> list[RepoSignals]:
    sem = asyncio.Semaphore(concurrency)

    async def _fetch(repo: RepoSignals) -> RepoSignals:
        async with sem:
            try:
                clones, uniques = await fetch_clone_traffic(client, org, repo.name)
            except (httpx.HTTPStatusError, httpx.RequestError):
                clones, uniques = -1, -1
            repo.clones_14d = clones
            repo.unique_cloners_14d = uniques
            return repo

    enriched = await asyncio.gather(*(_fetch(r) for r in repos))

    def _dist(values: list[int]) -> str:
        if not values:
            return "n/a"
        return f"min={values[0]} p50={values[len(values)//2]} max={values[-1]}"

    valid_clones = sorted(r.clones_14d for r in enriched if (r.clones_14d or 0) >= 0)
    valid_uniques = sorted(
        r.unique_cloners_14d for r in enriched if (r.unique_cloners_14d or 0) >= 0
    )
    errors = sum(1 for r in enriched if r.clones_14d == -1)
    console.print(
        f"  clone-count distribution: {_dist(valid_clones)} "
        f"zeros={sum(1 for c in valid_clones if c == 0)} errors={errors}"
    )
    console.print(
        f"  unique-cloners distribution: {_dist(valid_uniques)} "
        f"<=1={sum(1 for u in valid_uniques if u <= 1)}"
    )
    return [
        r for r in enriched
        if r.clones_14d is not None and 0 <= r.clones_14d <= max_clones
        and r.unique_cloners_14d is not None
        and 0 <= r.unique_cloners_14d <= max_unique_cloners
    ]


async def find_cross_refs(
    client: GitHubClient, org: str, repo: str
) -> tuple[int, list[str]]:
    """Search for references to {org}/{repo} in code, excluding self-references."""
    q = f'"{org}/{repo}" org:{org}'
    r = await client.get("/search/code", params={"q": q, "per_page": 100})
    r.raise_for_status()
    data = r.json()
    self_full_name = f"{org}/{repo}"
    external_items = [
        i for i in data.get("items", [])
        if i.get("repository", {}).get("full_name") != self_full_name
    ]
    files = [
        f"{i['repository']['full_name']}:{i['path']}" for i in external_items
    ]
    return len(external_items), files


async def apply_refs_filter(
    client: GitHubClient,
    org: str,
    repos: list[RepoSignals],
    rate_per_min: int = 30,
    max_refs: int = 1_000_000,
) -> list[RepoSignals]:
    delay = 60.0 / rate_per_min
    survivors: list[RepoSignals] = []
    for repo in repos:
        try:
            count, files = await find_cross_refs(client, org, repo.name)
        except (httpx.HTTPStatusError, httpx.RequestError):
            count, files = -1, []
        repo.internal_refs = count
        repo.internal_ref_files = files
        # -1 sentinel = lookup failed; treat as unknown and keep (humans review)
        if count == -1 or 0 <= count <= max_refs:
            survivors.append(repo)
        await asyncio.sleep(delay)
    return survivors


README_KEYWORDS = ("deprecated", "legacy", "do not use", "moved to", "archived")


def _decode_content(payload: dict) -> str | None:
    if not payload or payload.get("encoding") != "base64":
        return None
    try:
        return base64.b64decode(payload["content"]).decode("utf-8", errors="replace")
    except Exception:
        return None


async def _fetch_readme_keywords(
    client: GitHubClient, org: str, repo: str
) -> list[str]:
    r = await client.get(f"/repos/{org}/{repo}/contents/README.md")
    if r.status_code != 200:
        return []
    text = (_decode_content(r.json()) or "").lower()
    return [kw for kw in README_KEYWORDS if kw in text]


async def _fetch_codeowners_valid(client: GitHubClient, org: str, repo: str) -> bool:
    r = await client.get(f"/repos/{org}/{repo}/contents/CODEOWNERS")
    return r.status_code == 200


async def _fetch_latest_release(
    client: GitHubClient, org: str, repo: str
) -> datetime | None:
    r = await client.get(f"/repos/{org}/{repo}/releases/latest")
    if r.status_code != 200:
        return None
    return _parse_iso(r.json().get("published_at"))


async def _fetch_last_actions_run(
    client: GitHubClient, org: str, repo: str
) -> datetime | None:
    r = await client.get(f"/repos/{org}/{repo}/actions/runs", params={"per_page": 1})
    if r.status_code != 200:
        return None
    runs = r.json().get("workflow_runs", [])
    if not runs:
        return None
    return _parse_iso(runs[0].get("updated_at"))


async def enrich_soft_signals(
    client: GitHubClient,
    org: str,
    repos: list[RepoSignals],
    concurrency: int = 30,
) -> list[RepoSignals]:
    sem = asyncio.Semaphore(concurrency)

    async def _one(repo: RepoSignals) -> RepoSignals:
        async with sem:
            try:
                keywords, co_valid, release, actions = await asyncio.gather(
                    _fetch_readme_keywords(client, org, repo.name),
                    _fetch_codeowners_valid(client, org, repo.name),
                    _fetch_latest_release(client, org, repo.name),
                    _fetch_last_actions_run(client, org, repo.name),
                )
                repo.readme_keywords = keywords
                repo.codeowners_valid = co_valid
                repo.last_release_at = release
                repo.last_actions_at = actions
            except (httpx.HTTPStatusError, httpx.RequestError):
                pass  # leave soft-signal defaults
            return repo

    return await asyncio.gather(*(_one(r) for r in repos))


def score_candidate(r: RepoSignals) -> int:
    """Confidence 0 to 100. Higher = more confident the repo is safe to archive."""
    now = datetime.now(timezone.utc)
    score = 0

    # Default-branch commit age is the authoritative activity signal (replaces
    # pushed_at, which was destroyed by the GHE-to-EMU migration).
    if r.last_default_commit_at:
        years = (now - r.last_default_commit_at).days / 365
        score += min(30, max(0, int((years - 3) * 5)))

    if r.updated_at:
        years = (now - r.updated_at).days / 365
        score += min(20, max(0, int((years - 1) * 5)))

    if r.clones_14d == 0:
        score += 20

    if r.internal_refs == 0:
        score += 20

    score += min(10, len(r.readme_keywords) * 2)

    if r.codeowners_valid is False:
        score += 3

    return min(100, score)


CSV_FIELDS = [
    "repo", "archived", "fork", "last_default_commit_at",
    "pushed_at", "updated_at",
    "clones_14d", "unique_cloners_14d", "internal_refs",
    "readme_deprecated", "codeowners_valid", "open_issues", "open_prs",
    "last_release_at", "last_actions_at", "size_kb", "language",
    "stars", "forks", "confidence",
]


def _iso(d: datetime | None) -> str:
    return d.isoformat() if d else ""


def _row(r: RepoSignals) -> dict:
    return {
        "repo": r.name,
        "archived": r.archived,
        "fork": r.fork,
        "last_default_commit_at": _iso(r.last_default_commit_at),
        "pushed_at": _iso(r.pushed_at),
        "updated_at": _iso(r.updated_at),
        "clones_14d": r.clones_14d if r.clones_14d is not None else "",
        "unique_cloners_14d": r.unique_cloners_14d if r.unique_cloners_14d is not None else "",
        "internal_refs": r.internal_refs if r.internal_refs is not None else "",
        "readme_deprecated": ";".join(r.readme_keywords) if r.readme_keywords else "",
        "codeowners_valid": "" if r.codeowners_valid is None else r.codeowners_valid,
        "open_issues": r.open_issues,
        "open_prs": r.open_prs,
        "last_release_at": _iso(r.last_release_at),
        "last_actions_at": _iso(r.last_actions_at),
        "size_kb": r.size_kb,
        "language": r.language or "",
        "stars": r.stars,
        "forks": r.forks,
        "confidence": r.confidence,
    }


def emit_csv(candidates: list[RepoSignals], path: Path) -> None:
    with path.open("w", newline="") as f:
        w = _csv_mod.DictWriter(f, fieldnames=CSV_FIELDS)
        w.writeheader()
        for r in candidates:
            w.writerow(_row(r))


def emit_markdown(
    candidates: list[RepoSignals],
    path: Path,
    *,
    total_scanned: int,
    org: str,
) -> None:
    now = datetime.now(timezone.utc)
    today = now.date().isoformat()
    lines = [
        f"# {org} archive candidates, {today}",
        "",
        f"Scanned {total_scanned} repos in {org}. {len(candidates)} candidates flagged.",
        "",
        "## Candidates (sorted by confidence)",
        "",
    ]
    for r in sorted(candidates, key=lambda x: x.confidence, reverse=True):
        years_commit = (
            "?" if not r.last_default_commit_at
            else f"{(now - r.last_default_commit_at).days / 365:.1f}"
        )
        years_updated = (
            "?" if not r.updated_at else f"{(now - r.updated_at).days / 365:.1f}"
        )
        lines += [
            f"### {org}/{r.name}  [confidence: {r.confidence}]",
            "",
            f"- Last default-branch commit: {_iso(r.last_default_commit_at)} ({years_commit} years ago)",
            f"- Last updated: {_iso(r.updated_at)} ({years_updated} years ago)",
            f"- Clones (14d): {r.clones_14d}",
            f"- Internal references: {r.internal_refs}",
            f"- README keywords: {', '.join(r.readme_keywords) if r.readme_keywords else 'none'}",
            f"- CODEOWNERS: {'present' if r.codeowners_valid else 'missing'}",
            f"- Open issues: {r.open_issues}, Open PRs: {r.open_prs}",
            f"- Last release: {_iso(r.last_release_at) or 'none'}",
            f"- Last Actions run: {_iso(r.last_actions_at) or 'none'}",
            "- Suggested action: archive",
            "",
        ]
    path.write_text("\n".join(lines))


async def probe_token(client: GitHubClient, org: str, sentinel: str) -> None:
    """Verify token has clone-traffic access. Fail fast with remediation if not."""
    r = await client.get(f"/repos/{org}/{sentinel}/traffic/clones")
    if r.status_code == 403:
        raise RuntimeError(
            f"GITHUB_TOKEN lacks admin access to {org}/{sentinel}. "
            "Need org-admin classic PAT or fine-grained PAT with Administration:read."
        )


async def run_scan(cfg: Config) -> list[RepoSignals]:
    console.print(
        f"[bold]Scanning {cfg.org}[/bold] "
        f"(commit > {cfg.pushed_threshold_years}y, updated > {cfg.updated_threshold_years}y)"
    )
    if cfg.cache_dir:
        console.print(f"[dim]Cache dir: {cfg.cache_dir}[/dim]")

    stage1 = _cache_load(cfg.cache_dir, "stage1")
    if stage1 is None:
        console.print("Stage 1: discover + filter archived/fork/updated...")
        stage1 = discover_repos(cfg)
        _cache_save(cfg.cache_dir, "stage1", stage1)
    else:
        console.print("Stage 1: [cyan]using cache[/cyan]")
    console.print(f"  -> {len(stage1)} survivors")

    if not stage1:
        return []

    async with GitHubClient(org=cfg.org) as client:
        await probe_token(client, cfg.org, stage1[0].name)

        stage1_5 = _cache_load(cfg.cache_dir, "stage1_5")
        if stage1_5 is None:
            console.print("Stage 1.5: last default-branch commit (post-EMU-migration signal)...")
            stage1_5 = await apply_default_commit_age_filter(
                client, cfg.org, stage1,
                threshold_years=cfg.pushed_threshold_years,
                concurrency=cfg.concurrency,
            )
            _cache_save(cfg.cache_dir, "stage1_5", stage1_5)
        else:
            console.print("Stage 1.5: [cyan]using cache[/cyan]")
        console.print(f"  -> {len(stage1_5)} survivors")

        if not stage1_5:
            cfg.output_dir.mkdir(parents=True, exist_ok=True)
            emit_csv([], cfg.output_dir / "archive-candidates.csv")
            emit_markdown(
                [], cfg.output_dir / "archive-candidates.md",
                total_scanned=len(stage1), org=cfg.org,
            )
            console.print(f"[green]Done.[/green] 0 candidates written to {cfg.output_dir}")
            return []

        stage2 = _cache_load(cfg.cache_dir, "stage2")
        if stage2 is None:
            console.print("Stage 2: clone traffic...")
            stage2 = await apply_clone_filter(
                client, cfg.org, stage1_5,
                concurrency=cfg.concurrency,
                max_clones=cfg.max_clones,
                max_unique_cloners=cfg.max_unique_cloners,
            )
            _cache_save(cfg.cache_dir, "stage2", stage2)
        else:
            console.print("Stage 2: [cyan]using cache[/cyan]")
        console.print(f"  -> {len(stage2)} survivors")

        stage3 = _cache_load(cfg.cache_dir, "stage3")
        if stage3 is None and cfg.skip_refs:
            console.print("Stage 3: [yellow]skipped (--skip-refs)[/yellow]")
            stage3 = stage2
        elif stage3 is None:
            console.print("Stage 3: cross-reference search...")
            stage3 = await apply_refs_filter(
                client, cfg.org, stage2,
                rate_per_min=cfg.code_search_rate_per_min,
                max_refs=cfg.max_internal_refs,
            )
            _cache_save(cfg.cache_dir, "stage3", stage3)
        else:
            console.print("Stage 3: [cyan]using cache[/cyan]")
        console.print(f"  -> {len(stage3)} survivors")

        candidates = _cache_load(cfg.cache_dir, "stage4")
        if candidates is None:
            console.print("Stage 4: soft signals...")
            candidates = await enrich_soft_signals(
                client, cfg.org, stage3, concurrency=cfg.concurrency
            )
            _cache_save(cfg.cache_dir, "stage4", candidates)
        else:
            console.print("Stage 4: [cyan]using cache[/cyan]")

    for c in candidates:
        c.confidence = score_candidate(c)

    candidates.sort(key=lambda x: x.confidence, reverse=True)

    cfg.output_dir.mkdir(parents=True, exist_ok=True)
    emit_csv(candidates, cfg.output_dir / "archive-candidates.csv")
    emit_markdown(
        candidates,
        cfg.output_dir / "archive-candidates.md",
        total_scanned=len(stage1),
        org=cfg.org,
    )
    console.print(
        f"[green]Done.[/green] {len(candidates)} candidates written to {cfg.output_dir}"
    )
    return candidates


def main() -> int:
    cfg = parse_args()
    try:
        asyncio.run(run_scan(cfg))
        return 0
    except RuntimeError as e:
        console.print(f"[red]Error:[/red] {e}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
