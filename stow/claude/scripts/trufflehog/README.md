# trufflehog wrapper

Reusable filesystem secret-scan tooling. Wraps `trufflehog filesystem` with shared
exclude paths, deduplication by sha1, allowlist support, false-positive filtering,
and structured output.

## What it does

`trufflehog filesystem <target>` finds plausible secrets in files. This wrapper
adds:

1. A maintained `exclude-paths.txt` (build outputs, venvs, compiled binaries, `.git/`).
2. Per-credential dedupe via `sha1(Raw)[:12]` so the same key appearing in N files
   collapses to one row.
3. Two-tier triage: verified findings first, then unverified high-signal
   (AWS/GCP/PrivateKey/etc.), then everything else.
4. A regex filter (`placeholder-fp.txt`) that drops obvious template noise like
   `mongodb://username:password@host`. Only applies to unverified findings.
5. An allowlist (`allowlist.txt`) keyed by `(detector, sha1[:12])` for accepted
   findings.
6. `meta.json` per run: trufflehog version, duration, counts. Reproducibility.

## Dependencies

- `trufflehog` >= 3.95 (`brew install trufflehog`)
- `python3` (any 3.7+; uses only stdlib)

The wrapper checks for `trufflehog` on PATH and fails fast if missing.

## Quick start

```bash
bash ~/.claude/scripts/trufflehog-scan.sh /path/to/scan
```

Output lands in `~/.claude/scripts/trufflehog/runs/<timestamp>/`.

Show flags: `bash ~/.claude/scripts/trufflehog-scan.sh --help`

## Flags

| Flag | Effect |
|---|---|
| `--verified-only` | Only run verified findings. Fast. Good for CI / pre-commit. |
| `--include-git` | Include `.git/` in the scan. Use for history audits; pulls in packfile dupes. |
| `--no-fp-filter` | Skip `placeholder-fp.txt`. Useful for debugging the FP filter. |
| `--fail-on-verified` | Exit `2` if any verified findings remain after allowlist. CI signal. |
| `-h`, `--help` | Print usage. |

Default mode: verified + unverified, with FP filter on, `.git/` excluded.

## File layout (this directory)

| File | Purpose |
|---|---|
| `exclude-paths.txt` | RE2 patterns passed to `trufflehog --exclude-paths`. Edit to scope scans. |
| `allowlist.txt` | Accepted findings, keyed by `(detector, sha1[:12])`. Drop noise *after* triage. |
| `placeholder-fp.txt` | Python regex applied to Raw value. Drops unverified placeholders. Never filters verified. |
| `findings-log.md` | Running audit log of triaged findings. Append-only. |
| `runs/<ts>/` | Output of each scan run (see below). |
| `README.md` | This file. |

## Output structure (`runs/<timestamp>/`)

| File | Contents |
|---|---|
| `findings.jsonl` | Raw trufflehog JSONL output. One match per line. |
| `triage.csv` | Deduped + allowlisted + FP-filtered. The main artifact. |
| `meta.json` | Run metadata (version, duration, counts). |
| `exclude-paths.effective.txt` | The exclude patterns actually applied (comments stripped). |
| `trufflehog.stderr.log` | Stderr from trufflehog (verifier errors, brotli warnings). |

## Triage CSV columns

| Column | Meaning |
|---|---|
| `detector` | Trufflehog detector name (`AWS`, `GCP`, `SlackWebhook`, etc.). |
| `raw_prefix` | First 30 chars of the matched secret. For humans, not matching. |
| `raw_sha1_12` | `sha1(raw)[:12]`. Stable dedupe and allowlist key across runs. |
| `verified` | `True` if trufflehog confirmed the secret via live API call. |
| `high_signal` | `True` if detector is in the high-signal set (see below). |
| `occurrences` | How many raw matches collapsed into this row. |
| `sample_locations` | Up to 5 `path:line` examples. |

Rows are sorted: verified first, then high-signal unverified, then everything else.

## Tiers

**Verified**: trufflehog reached the service's API and the credential authenticated.
Real, live, exploitable. Rotate immediately.

**Unverified high-signal**: pattern matches a high-impact detector
(`AWS`, `GCP`, `AzureStorage`, `PrivateKey`, `Github`, `Gitlab`, `Slack`,
`SlackWebhook`, `Twilio`, `Cloudflare`, `CloudflareApiToken`, `PagerDutyApiKey`,
`LaunchDarkly`, `OpenAI`, `Anthropic`, `Stripe`, `Snyk`, `Postgres`, `MySQL`,
`MongoDB`, `RabbitMQ`, `JWT`, `Datadog`, `Auth0`) but verification failed.
Causes: credential revoked, service rate-limited the verify call, raw private
key (no service to verify against), network glitch. Eyeball each one. Revoked
keys still committed to git are bad hygiene and may have been indexed by
crawlers.

**Unverified other**: lower-signal detectors. Mostly noise (placeholder URIs,
generic API keys, etc.). Skim for surprises.

## Allowlist workflow

After eyeballing the triage CSV, accept findings that are intentional / safe:

```text
# allowlist.txt format:
# <detector>|<raw_sha1_12>|<reason>|<reviewed-on>
SlackWebhook|d5a7f2339596|cloud-custodian alert to #cloud-alerts|2026-05-11
```

Keys come from the `raw_sha1_12` column of the triage CSV. Match is exact, so
allowlisting one credential never silences a different credential that happens
to share a human-readable prefix.

Rule: **don't allowlist a verified credential to silence noise. Rotate it first.**

## Tweaking exclude paths

`exclude-paths.txt` uses RE2 (Go regex). Match is on full file path. Each line:
either a regex or a comment (lines starting with `#` or with `#` after whitespace).

Common additions:

```
(^|/)mydir/             # skip a project-specific dir
\.bak\.gz$              # compressed backups
(^|/)snapshots/.*\.html$  # rendered state snapshots
```

Don't exclude `.tfstate*` — that's a known place real secrets leak from backend
writes.

## Tweaking FP patterns

`placeholder-fp.txt` uses Python regex (`re.search`). Match is against the Raw
value. Each match drops one unverified finding. Verified findings are never
filtered.

Add a pattern only when you're sure the value is a placeholder / template, not
a real credential. Example:

```
^(?:fake|dummy|placeholder|changeme)[-_]?(?:key|token|secret|password)?$
```

## Reading the summary

The wrapper prints a one-line summary at the end:

```
→ unique findings: 163 (verified=11, unverified-high-signal=32, unverified-other=120); fp-filter dropped 48 unverified hits
```

What to do:

| Tier count | Action |
|---|---|
| `verified > 0` | Rotate / remove + write back to the issue tracker. Each one is a live leak. |
| `unverified-high-signal > 0` | Eyeball each row. Likely real but couldn't verify (revoked, rate-limited, private key). |
| `unverified-other > 0` | Skim for surprises. Mostly low-signal noise. |

## Reading `meta.json`

Run-level facts. Useful for diffing runs over time:

```json
{
  "trufflehog_version": "3.95.2",
  "started": "...",
  "ended": "...",
  "duration_seconds": 45,
  "target": "/Users/user/git/work",
  "verified_only": false,
  "include_git": false,
  "fp_filter_enabled": true,
  "raw_findings": 987,
  "total_parsed": 987,
  "fp_filter_dropped": 48,
  "unique_findings": 163,
  "unique_verified": 11,
  "unique_unverified_high_signal": 32,
  "unique_unverified_other": 120,
  "exclude_patterns": 47
}
```

## Diffing runs

To see what changed since the last scan:

```bash
prev=$(ls -td ~/.claude/scripts/trufflehog/runs/*/ | sed -n '2p')
curr=$(ls -td ~/.claude/scripts/trufflehog/runs/*/ | head -1)

python3 -c "
import csv
def keys(p):
    return {(r['detector'], r['raw_sha1_12']): r for r in csv.DictReader(open(p))}
P = keys('${prev}triage.csv'); C = keys('${curr}triage.csv')
print('resolved:', sorted(set(P)-set(C)))
print('new:    ', sorted(set(C)-set(P)))
"
```

## CI usage

```bash
bash ~/.claude/scripts/trufflehog-scan.sh "$PWD" --verified-only --fail-on-verified
```

- `--verified-only`: cuts scan time (skips unverified noise).
- `--fail-on-verified`: exits `2` if any verified finding survives the allowlist.

Pre-commit hook variant: run `--verified-only --fail-on-verified` on the staged
file set before allowing commit. (Pre-commit setup left to the user; not included
in this wrapper.)

## Non-Claude / fresh-shell usage

Nothing in the wrapper depends on Claude Code being loaded. As long as the four
config files (`exclude-paths.txt`, `allowlist.txt`, `placeholder-fp.txt`,
optional `findings-log.md`) live in `~/.claude/scripts/trufflehog/` and
`trufflehog` is on PATH, the wrapper runs anywhere. To use on another machine:
rsync `~/.claude/scripts/trufflehog-scan.sh` and `~/.claude/scripts/trufflehog/`
to the same paths.

## Known limitations

- **Verification is non-deterministic.** Slack, GitHub, etc. rate-limit verify
  calls. A token verified in one run may show up unverified in the next. Always
  treat `unverified-high-signal` as "real until proven otherwise."
- **Adjacent secrets miss the radar.** Trufflehog flags a Twilio Account SID but
  not the auth token on the next line, because the auth token is a plain
  32-char hex string with no distinguishing pattern. Manually check the
  surrounding lines of any verified finding.
- **Compressed compiled binaries are excluded by default.** A `.gz`-compressed
  Go binary with embedded strings was producing dozens of false positives.
  Re-enable scanning with `--include-git` and editing `exclude-paths.txt` if
  you need it.
- **No git-history mode.** Use `trufflehog git file://<repo>` directly for
  branch/tag/deleted-blob history. The filesystem wrapper does not walk git
  history even with `--include-git` (that flag only includes `.git/` packfiles
  as files).

## Provenance

Built up over conversations on 2026-05-10 and 2026-05-11. See git log of this
file and `findings-log.md` for the audit trail.
