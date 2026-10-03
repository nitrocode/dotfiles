#!/usr/bin/env bash
# visibility: internal
# trufflehog-scan.sh — wrapper for filesystem trufflehog scans.
# Inputs: $1 = scan target (default: cwd). Optional flags below.
# Outputs: writes raw JSONL + triage CSV + meta.json under ~/.claude/scripts/trufflehog/runs/<timestamp>/
#
# By default the scan includes BOTH verified and unverified findings. Unverified
# findings are filtered through placeholder-fp.txt to drop obvious template /
# placeholder noise. Verified findings are never FP-filtered.
#
# Flags:
#   --verified-only       only run verified hits (fast; same as old default). Good for CI.
#   --include-git         include .git/ in scan (bypass the exclude rule).
#   --no-fp-filter        keep unverified findings even if they match placeholder-fp.txt.
#   --fail-on-verified    exit 2 if any verified findings remain after allowlist.
#
# Config files (versioned in ~/.claude/scripts/trufflehog/):
#   exclude-paths.txt    — RE2 path patterns to skip
#   allowlist.txt        — accepted findings (matched by detector + sha1[:12])
#   placeholder-fp.txt   — regex patterns dropping placeholder unverified findings
#   findings-log.md      — running audit log (manual)

set -euo pipefail

CONFIG_DIR="${HOME}/.claude/scripts/trufflehog"
EXCLUDE_FILE="${CONFIG_DIR}/exclude-paths.txt"
ALLOWLIST_FILE="${CONFIG_DIR}/allowlist.txt"
FP_FILE="${CONFIG_DIR}/placeholder-fp.txt"

usage() {
  cat <<EOF
trufflehog-scan.sh — wrapper around \`trufflehog filesystem\` with shared config.

Usage: trufflehog-scan.sh [TARGET] [FLAGS]
  TARGET  Directory to scan (default: current working directory).

Flags:
  --verified-only       Run only verified findings (fast; CI-friendly).
  --include-git         Include .git/ (bypass the default exclude).
  --no-fp-filter        Keep unverified placeholders (skip placeholder-fp.txt filter).
  --fail-on-verified    Exit 2 if any verified findings remain after allowlist.
  -h, --help            Show this message.

Output: ${CONFIG_DIR}/runs/<timestamp>/{findings.jsonl,triage.csv,meta.json,...}

Full docs: ${CONFIG_DIR}/README.md
EOF
}

# Pre-parse: handle -h/--help as the first argument so it doesn't get treated as TARGET.
case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
esac

target="${1:-.}"
shift || true

include_git=0
verified_only=0
fail_on_verified=0
fp_filter=1
for arg in "$@"; do
  case "$arg" in
    -h|--help|help) usage; exit 0 ;;
    --include-git) include_git=1 ;;
    --verified-only) verified_only=1 ;;
    --no-fp-filter) fp_filter=0 ;;
    --fail-on-verified) fail_on_verified=1 ;;
    --all) ;; # legacy alias — was "include unverified", which is now the default
    *) echo "unknown flag: $arg" >&2; echo >&2; usage >&2; exit 2 ;;
  esac
done

command -v trufflehog >/dev/null || { echo "trufflehog not found (brew install trufflehog)" >&2; exit 1; }
[[ -f "$EXCLUDE_FILE" ]] || { echo "missing $EXCLUDE_FILE" >&2; exit 1; }

ts="$(date +%Y%m%d-%H%M%S)"
outdir="${CONFIG_DIR}/runs/${ts}"
mkdir -p "$outdir"

effective_exclude="${outdir}/exclude-paths.effective.txt"
sed -E 's/[[:space:]]+#.*$//; /^[[:space:]]*$/d; /^[[:space:]]*#/d' "$EXCLUDE_FILE" > "$effective_exclude"
if [[ $include_git -eq 1 ]]; then
  sed -i.bak '/\\.git\//d' "$effective_exclude"
  rm -f "${effective_exclude}.bak"
fi

raw_jsonl="${outdir}/findings.jsonl"
err_log="${outdir}/trufflehog.stderr.log"
meta_json="${outdir}/meta.json"
triage_csv="${outdir}/triage.csv"

cmd=(trufflehog filesystem "$target" --no-update --json --exclude-paths "$effective_exclude")
[[ $verified_only -eq 1 ]] && cmd+=(--only-verified)

trufflehog_version="$(trufflehog --version 2>&1 | head -1 | awk '{print $NF}')"
started_epoch="$(date +%s)"
started_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "→ scanning: $target" >&2
echo "→ trufflehog version: $trufflehog_version" >&2
echo "→ exclude: $effective_exclude ($(wc -l < "$effective_exclude") patterns)" >&2
echo "→ verified-only: $verified_only, include-git: $include_git, fp-filter: $fp_filter, fail-on-verified: $fail_on_verified" >&2

"${cmd[@]}" 2>"$err_log" > "$raw_jsonl" || true

ended_epoch="$(date +%s)"
ended_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
duration_s=$((ended_epoch - started_epoch))
raw_count="$(wc -l < "$raw_jsonl" | tr -d ' ')"

echo "→ raw findings: $raw_count lines → $raw_jsonl (took ${duration_s}s)" >&2

tally_file="${outdir}/.tally"
python3 - "$raw_jsonl" "$ALLOWLIST_FILE" "$FP_FILE" "$triage_csv" "$tally_file" "$fp_filter" <<'PY'
import csv, hashlib, json, re, sys
from collections import defaultdict

jsonl_path, allow_path, fp_path, out_path, tally_path, fp_filter_flag = sys.argv[1:7]
fp_filter_on = fp_filter_flag == "1"

# High-signal detectors get explicit credit in the summary even when unverified —
# private keys, AWS/GCP/Azure creds, and major SaaS tokens are too risky to ignore
# just because trufflehog couldn't reach the verifier.
HIGH_SIGNAL = {
    "AWS", "GCP", "AzureStorage", "PrivateKey", "Github", "GithubApp", "Gitlab",
    "Slack", "SlackWebhook", "Twilio", "Cloudflare", "CloudflareApiToken",
    "PagerDutyApiKey", "LaunchDarkly", "OpenAI", "Anthropic", "Stripe", "Snyk",
    "SnykKey", "Postgres", "MySQL", "MongoDB", "RabbitMQ", "JWT",
    "Datadog", "Auth0",
}

allow_sha = set()
allow_prefix_legacy = set()
try:
    with open(allow_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"): continue
            parts = [p.strip() for p in line.split("|")]
            if len(parts) < 2: continue
            det, key = parts[0], parts[1]
            if len(key) == 12 and all(c in "0123456789abcdef" for c in key):
                allow_sha.add((det, key))
            else:
                allow_prefix_legacy.add((det, key[:30]))
except FileNotFoundError:
    pass

fp_patterns = []
if fp_filter_on:
    try:
        with open(fp_path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"): continue
                try:
                    fp_patterns.append(re.compile(line))
                except re.error as e:
                    print(f"warn: bad regex in {fp_path}: {line} ({e})", file=sys.stderr)
    except FileNotFoundError:
        pass

def is_fp(raw):
    return any(p.search(raw) for p in fp_patterns)

groups = defaultdict(lambda: {"count": 0, "files": [], "verified": False, "prefix": "", "detector": ""})
total = 0
fp_dropped = 0
with open(jsonl_path) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try: r = json.loads(line)
        except json.JSONDecodeError: continue
        total += 1
        det = r.get("DetectorName", "?")
        raw = r.get("Raw", "")
        prefix = raw[:30]
        h = hashlib.sha1(raw.encode("utf-8", "replace")).hexdigest()[:12]
        if (det, h) in allow_sha: continue
        if (det, prefix) in allow_prefix_legacy: continue
        verified = bool(r.get("Verified"))
        # Drop unverified placeholders (verified findings are never FP-filtered).
        if not verified and is_fp(raw):
            fp_dropped += 1
            continue
        fs = r.get("SourceMetadata", {}).get("Data", {}).get("Filesystem", {})
        loc = f"{fs.get('file','?')}:{fs.get('line','?')}"
        g = groups[(det, h)]
        g["count"] += 1
        g["prefix"] = prefix
        g["detector"] = det
        if loc not in g["files"] and len(g["files"]) < 5:
            g["files"].append(loc)
        g["verified"] = g["verified"] or verified

verified_unique = sum(1 for g in groups.values() if g["verified"])
high_unverified = sum(1 for g in groups.values() if not g["verified"] and g["detector"] in HIGH_SIGNAL)
other_unverified = sum(1 for g in groups.values() if not g["verified"] and g["detector"] not in HIGH_SIGNAL)

# Sort: verified first (by count desc), then high-signal unverified, then everything else.
def sort_key(item):
    (det, _h), g = item
    tier = 0 if g["verified"] else (1 if det in HIGH_SIGNAL else 2)
    return (tier, -g["count"], det)

with open(out_path, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["detector","raw_prefix","raw_sha1_12","verified","high_signal","occurrences","sample_locations"])
    for (det, h), g in sorted(groups.items(), key=sort_key):
        w.writerow([det, g["prefix"], h, g["verified"], det in HIGH_SIGNAL, g["count"], " ; ".join(g["files"])])

with open(tally_path, "w") as f:
    f.write(f"{len(groups)} {verified_unique} {high_unverified} {other_unverified} {total} {fp_dropped}\n")

print(f"→ unique findings: {len(groups)} (verified={verified_unique}, "
      f"unverified-high-signal={high_unverified}, unverified-other={other_unverified}); "
      f"fp-filter dropped {fp_dropped} unverified hits", file=sys.stderr)
PY

read unique_count verified_unique high_unverified other_unverified total_findings fp_dropped < "$tally_file"
rm -f "$tally_file"

cat > "$meta_json" <<JSON
{
  "trufflehog_version": "${trufflehog_version}",
  "started": "${started_iso}",
  "ended": "${ended_iso}",
  "duration_seconds": ${duration_s},
  "target": "${target}",
  "verified_only": $([ $verified_only -eq 1 ] && echo true || echo false),
  "include_git": $([ $include_git -eq 1 ] && echo true || echo false),
  "fp_filter_enabled": $([ $fp_filter -eq 1 ] && echo true || echo false),
  "raw_findings": ${raw_count},
  "total_parsed": ${total_findings},
  "fp_filter_dropped": ${fp_dropped},
  "unique_findings": ${unique_count},
  "unique_verified": ${verified_unique},
  "unique_unverified_high_signal": ${high_unverified},
  "unique_unverified_other": ${other_unverified},
  "exclude_patterns": $(wc -l < "$effective_exclude" | tr -d ' ')
}
JSON

echo "→ triage CSV: $triage_csv" >&2
echo "→ meta: $meta_json" >&2

if [[ $fail_on_verified -eq 1 && $verified_unique -gt 0 ]]; then
  echo "→ FAIL: ${verified_unique} verified finding(s) remain after allowlist." >&2
  exit 2
fi

echo "→ done."
