# gdoc-apply-edits

Apply a structured edit-list to a Google Doc, preserving the doc's existing formatting. Backed by a Google Apps Script using `DocumentApp` native APIs (not markdown-to-doc conversion, which would clobber formatting and comments).

## One-time setup

1. **Install clasp**

   ```bash
   npm i -g @google/clasp
   clasp --version
   ```

2. **Log in with the Google account that owns or can edit the target docs**

   ```bash
   clasp login
   ```

   Opens a browser; sign in with the Google account that has edit access to the doc.

3. **Enable the Apps Script API for your account**

   Visit https://script.google.com/home/usersettings and toggle "Google Apps Script API" to ON.

4. **Create a new Apps Script project bound to this directory**

   ```bash
   cd ~/.claude/scripts/gdoc-apply-edits
   clasp create --type standalone --title "gdoc-apply-edits"
   ```

   This writes a `.clasp.json` file pinning the project's `scriptId`.

5. **Push the code**

   ```bash
   clasp push
   ```

6. **Deploy as an executable API (one-time)**

   ```bash
   clasp deploy --description "v1"
   ```

   Then open the script in the Apps Script editor (`clasp open`) and:
   - Click Run on `applyEdits` once to trigger the consent flow (it will fail with a missing-payload error; that's expected).
   - Accept the OAuth scopes (Documents, External Requests).

   After consent, the script can be invoked via `clasp run`.

## Usage

```bash
# File-based edits
~/.claude/scripts/gdoc-apply-edits.sh \
  --doc-id 1GqzcF_vqRyWyBett56a0z4Ya6gObI2NezsuQ2hYK5Tw \
  --edits ./edits.json

# Or via stdin
jq -n '[
  {"type":"replace","find":"3 Flavors","replace":"4 Flavors"}
]' | ~/.claude/scripts/gdoc-apply-edits.sh \
  --doc-id 1GqzcF_vqRyWyBett56a0z4Ya6gObI2NezsuQ2hYK5Tw \
  --edits-stdin
```

The script prints the Apps Script return value as JSON: `{"applied": N, "skipped": [...], "errors": [...]}`.

## Edit types

### `replace`
Plain-text find-and-replace. Preserves surrounding formatting.

```json
{"type": "replace", "find": "3 Flavors", "replace": "4 Flavors"}
```

### `replaceRegex`
Same as above, but `pattern` is treated as a regex.

```json
{"type": "replaceRegex", "pattern": "All (three|3) flows", "replace": "All four flows"}
```

### `insertParagraphAfter`
Insert a single paragraph after the first paragraph whose text contains `afterText`. Optional `heading` styles the new paragraph.

```json
{
  "type": "insertParagraphAfter",
  "afterText": "Flow 3: Non-Code Content Repositories",
  "content": "Flow 4: Restricted Read-Access Repositories",
  "heading": "HEADING1"
}
```

### `insertSectionAfter`
Insert multiple paragraphs after an anchor heading. Each paragraph can have its own heading style.

```json
{
  "type": "insertSectionAfter",
  "afterHeading": "Cross-Cutting Enablers",
  "paragraphs": [
    {"text": "E.6: Restricted Read-Access Pattern", "heading": "HEADING2"},
    {"text": "Read access is opt-in...", "heading": "NORMAL"}
  ]
}
```

Heading values: `TITLE`, `SUBTITLE`, `HEADING1` through `HEADING6`, `NORMAL`.

## Behavior

- **Idempotent on `replace`**: if `find` is not in the doc, the edit is recorded as `skipped` (with reason) rather than failing the whole batch.
- **Atomic per edit, not per batch**: each edit either applies or is skipped/errored. The doc is saved once at the end via `saveAndClose()`.
- **Edits run in order**. If later edits depend on text inserted by earlier ones, list them in that order.

## Limitations

- No comments / suggestion-mode support. Edits apply directly. For suggestion-mode redlines, use the Google Docs UI manually.
- No table-cell-level edits in v1. Tables are findable via `replace` text inside cells, but adding new tables requires a future edit type.
- `clasp run` requires the script project to be deployed and the API enabled for your account. If `clasp run` returns "Script API not enabled," recheck step 3.

## Testing

```bash
bash ~/.claude/scripts/tests/test-gdoc-apply-edits.sh
```

Tests mock `clasp` via a PATH shim. No Google API calls happen during testing.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Script API not enabled` | Step 3 skipped | Toggle on at https://script.google.com/home/usersettings |
| `Login Required` from clasp | `clasp login` expired | Re-run `clasp login` |
| Edits applied but doc visually unchanged | Anchor text not unique enough or doc cached in browser | Reload the doc; check `skipped[]` in output |
| Permission denied opening doc | Account does not have edit access to the docId | Switch accounts (`clasp logout && clasp login`) or get edit access |
