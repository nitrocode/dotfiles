#!/usr/bin/env bash
# Generic CSV-to-Google-Sheet uploader via the `gdrive` rclone remote. Source
# is either a single .csv file or a directory of .csv files (non-recursive
# by default). Idempotent: skips any file whose derived target title already
# exists in the destination folder unless --overwrite is given. Conversion
# to a native Sheet requires staging the source under a filename that already
# carries the exact target title plus a .csv extension before `rclone copy`
# runs; a destination-side rename after upload does not work reliably.
#
# A single file's upload failure does not abort the batch; it is logged and
# the loop continues (see bulk-operations.md).
#
# Inputs:
#   $1 - source: a single .csv file, or a directory containing .csv files
#   $2 - destination Drive folder path on the rclone remote
#   --recursive          also search subdirectories of a directory source
#   --title-prefix TEXT  prepended to every filename-derived title (default: "")
#   --title TEXT         explicit title override; only valid for a single-file
#                         source (error if combined with a directory source)
#   --overwrite          delete an existing same-titled Drive file (using its
#                         actual returned name), then re-upload
#   --dry-run            print intended actions only; no rclone copy/deletefile calls
#
# Env overrides:
#   RCLONE_REMOTE  rclone remote name (default: gdrive)
#
# Output:
#   One progress line per file (uploaded / skipped-exists / failed), then a
#   summary line: "uploaded N, skipped N, failed N".
#
# Example:
#   upload-csv-to-drive.sh /tmp/report.csv "My Folder"
#   upload-csv-to-drive.sh /tmp/reports "My Folder" --recursive --title-prefix "Report - "
#   upload-csv-to-drive.sh /tmp/report.csv "My Folder" --title "Q4 Report" --overwrite
set -uo pipefail # deliberately not -e: one file's failure must not abort the batch

RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive}"

RECURSIVE=0
OVERWRITE=0
DRY_RUN=0
TITLE_PREFIX=""
TITLE_OVERRIDE=""
positional=()

args=("$@")
i=0
while (( i < ${#args[@]} )); do
  arg="${args[$i]}"
  case "$arg" in
    --recursive) RECURSIVE=1 ;;
    --overwrite) OVERWRITE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --title-prefix)
      i=$((i + 1))
      TITLE_PREFIX="${args[$i]:?--title-prefix requires a value}"
      ;;
    --title)
      i=$((i + 1))
      TITLE_OVERRIDE="${args[$i]:?--title requires a value}"
      ;;
    *) positional+=("$arg") ;;
  esac
  i=$((i + 1))
done

source_path="${positional[0]:?usage: upload-csv-to-drive.sh <source-csv-or-dir> <dest-drive-folder> [--recursive] [--title-prefix TEXT] [--title TEXT] [--overwrite] [--dry-run]}"
dest_folder="${positional[1]:?usage: upload-csv-to-drive.sh <source-csv-or-dir> <dest-drive-folder> [--recursive] [--title-prefix TEXT] [--title TEXT] [--overwrite] [--dry-run]}"
remote_path="${RCLONE_REMOTE}:${dest_folder}"

if [[ -f "$source_path" ]]; then
  csv_files=("$source_path")
elif [[ -d "$source_path" ]]; then
  if [[ -n "$TITLE_OVERRIDE" ]]; then
    echo "error: --title cannot be combined with a directory source" >&2
    exit 1
  fi
  if [[ "$RECURSIVE" -eq 1 ]]; then
    mapfile -t csv_files < <(find "$source_path" -type f -name '*.csv' | sort)
  else
    mapfile -t csv_files < <(find "$source_path" -maxdepth 1 -type f -name '*.csv' | sort)
  fi
else
  echo "error: source '${source_path}' is not a file or directory" >&2
  exit 1
fi

staging_dir="$(mktemp -d)"
cleanup() { rm -rf "$staging_dir"; }
trap cleanup EXIT

# List the destination folder once (not once per file). Tolerate the folder
# not existing yet (rclone copy will create it on first real upload).
existing_json="$(rclone lsjson "$remote_path" 2>/dev/null || echo '[]')"
[[ -z "$existing_json" ]] && existing_json='[]'

# Returns the exact Drive Name for an existing file matching $1 (target
# title, no extension). `rclone lsjson` reports converted native Sheets with
# a virtual export-format extension appended (e.g. ".xlsx", per
# --drive-export-formats), not the source ".csv"; strip whichever trailing
# extension is present before comparing.
existing_name_for() {
  local target="$1"
  echo "$existing_json" | jq -r --arg t "$target" \
    '.[] | select((.Name | sub("\\.[^.]+$"; "")) == $t) | .Name' | head -n1
}

total="${#csv_files[@]}"
echo "Found ${total} CSV file(s) at ${source_path}."

uploaded=0
skipped=0
failed=0

for csv_file in "${csv_files[@]}"; do
  base="$(basename "$csv_file")"
  base="${base%.csv}"
  label="$base"

  if [[ -n "$TITLE_OVERRIDE" ]]; then
    target_title="$TITLE_OVERRIDE"
  else
    target_title="${TITLE_PREFIX}${base}"
  fi
  staged_name="${target_title}.csv"
  staged_file="${staging_dir}/${staged_name}"

  existing_name="$(existing_name_for "$target_title")"

  if [[ -n "$existing_name" && "$OVERWRITE" -eq 0 ]]; then
    echo "${label}: skipped-exists ('${existing_name}' already in ${dest_folder})"
    skipped=$((skipped + 1))
    continue
  fi

  if [[ -n "$existing_name" && "$OVERWRITE" -eq 1 ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "${label}: [dry-run] would delete '${existing_name}' then re-upload as '${target_title}'"
      uploaded=$((uploaded + 1))
      continue
    fi
    if ! rclone deletefile "${remote_path}/${existing_name}" 2>"${staging_dir}/${label}.delete.log"; then
      echo "${label}: failed (deletefile error, see ${staging_dir}/${label}.delete.log)"
      failed=$((failed + 1))
      continue
    fi
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "${label}: [dry-run] would upload as '${target_title}'"
    uploaded=$((uploaded + 1))
    continue
  fi

  cp "$csv_file" "$staged_file"

  if rclone copy "$staged_file" "$remote_path" \
    --drive-import-formats csv \
    --drive-export-formats csv,xlsx \
    --drive-allow-import-name-change \
    >"${staging_dir}/${label}.copy.log" 2>&1; then
    echo "${label}: uploaded as '${target_title}'"
    uploaded=$((uploaded + 1))
  else
    echo "${label}: failed (rclone copy error, see ${staging_dir}/${label}.copy.log)"
    failed=$((failed + 1))
  fi

  rm -f "$staged_file"
done

echo ""
echo "uploaded ${uploaded}, skipped ${skipped}, failed ${failed}"
