/**
 * gdoc-apply-edits, apply a structured edit-list to a Google Doc.
 *
 * Designed to be invoked via `clasp run applyEdits --params '[{...}]'`.
 *
 * Edit types supported:
 *   {"type": "replace",              "find": <string>, "replace": <string>}
 *   {"type": "replaceRegex",         "pattern": <regex>, "replace": <string>}
 *   {"type": "insertParagraphAfter", "afterText": <string>, "content": <string>, "heading"?: <HeadingType>}
 *   {"type": "insertSectionAfter",   "afterHeading": <string>, "paragraphs": [{"text": <string>, "heading"?: <HeadingType>}, ...]}
 *
 * HeadingType values: "HEADING1", "HEADING2", "HEADING3", "HEADING4", "HEADING5", "HEADING6", "NORMAL", "TITLE", "SUBTITLE".
 *
 * Returns a summary object: {applied: N, skipped: [...], errors: [...]}.
 * The function never throws on per-edit failures; it collects them in `errors`.
 * Top-level failures (bad docId, doc not accessible) do throw.
 */

function applyEdits(payload) {
  if (!payload || typeof payload !== 'object') {
    throw new Error('payload must be an object: {docId, edits}');
  }
  var docId = payload.docId;
  var edits = payload.edits;
  if (!docId || typeof docId !== 'string') {
    throw new Error('payload.docId is required (string)');
  }
  if (!Array.isArray(edits)) {
    throw new Error('payload.edits is required (array)');
  }

  var doc = DocumentApp.openById(docId);
  var body = doc.getBody();
  var summary = { applied: 0, skipped: [], errors: [] };

  for (var i = 0; i < edits.length; i++) {
    var e = edits[i];
    try {
      var result = applyOne_(body, e);
      if (result.applied) {
        summary.applied++;
      } else {
        summary.skipped.push({ index: i, edit: e, reason: result.reason });
      }
    } catch (err) {
      summary.errors.push({ index: i, edit: e, error: String(err && err.message || err) });
    }
  }

  doc.saveAndClose();
  return summary;
}

function applyOne_(body, edit) {
  if (!edit || typeof edit !== 'object' || !edit.type) {
    return { applied: false, reason: 'edit missing type' };
  }
  switch (edit.type) {
    case 'replace':
      return doReplace_(body, edit);
    case 'replaceRegex':
      return doReplaceRegex_(body, edit);
    case 'insertParagraphAfter':
      return doInsertParagraphAfter_(body, edit);
    case 'insertSectionAfter':
      return doInsertSectionAfter_(body, edit);
    default:
      return { applied: false, reason: 'unknown edit type: ' + edit.type };
  }
}

function doReplace_(body, edit) {
  if (typeof edit.find !== 'string' || typeof edit.replace !== 'string') {
    return { applied: false, reason: 'replace requires string find and replace' };
  }
  var pattern = escapeRegex_(edit.find);
  var found = body.findText(pattern);
  if (!found) {
    return { applied: false, reason: 'find string not present' };
  }
  body.replaceText(pattern, edit.replace);
  return { applied: true };
}

function doReplaceRegex_(body, edit) {
  if (typeof edit.pattern !== 'string' || typeof edit.replace !== 'string') {
    return { applied: false, reason: 'replaceRegex requires string pattern and replace' };
  }
  var found = body.findText(edit.pattern);
  if (!found) {
    return { applied: false, reason: 'pattern did not match' };
  }
  body.replaceText(edit.pattern, edit.replace);
  return { applied: true };
}

function doInsertParagraphAfter_(body, edit) {
  if (typeof edit.afterText !== 'string' || typeof edit.content !== 'string') {
    return { applied: false, reason: 'insertParagraphAfter requires afterText and content' };
  }
  var anchorIdx = findParagraphIndex_(body, edit.afterText);
  if (anchorIdx < 0) {
    return { applied: false, reason: 'afterText not found' };
  }
  var p = body.insertParagraph(anchorIdx + 1, edit.content);
  if (edit.heading) {
    p.setHeading(resolveHeading_(edit.heading));
  }
  return { applied: true };
}

function doInsertSectionAfter_(body, edit) {
  if (typeof edit.afterHeading !== 'string' || !Array.isArray(edit.paragraphs)) {
    return { applied: false, reason: 'insertSectionAfter requires afterHeading and paragraphs' };
  }
  var anchorIdx = findParagraphIndex_(body, edit.afterHeading);
  if (anchorIdx < 0) {
    return { applied: false, reason: 'afterHeading not found' };
  }
  for (var i = 0; i < edit.paragraphs.length; i++) {
    var par = edit.paragraphs[i];
    if (!par || typeof par.text !== 'string') {
      return { applied: false, reason: 'paragraphs[' + i + '] missing text' };
    }
    var p = body.insertParagraph(anchorIdx + 1 + i, par.text);
    if (par.heading) {
      p.setHeading(resolveHeading_(par.heading));
    }
  }
  return { applied: true };
}

function findParagraphIndex_(body, text) {
  var paragraphs = body.getParagraphs();
  for (var i = 0; i < paragraphs.length; i++) {
    if (paragraphs[i].getText().indexOf(text) !== -1) {
      return i;
    }
  }
  return -1;
}

function resolveHeading_(name) {
  var map = {
    'TITLE': DocumentApp.ParagraphHeading.TITLE,
    'SUBTITLE': DocumentApp.ParagraphHeading.SUBTITLE,
    'HEADING1': DocumentApp.ParagraphHeading.HEADING1,
    'HEADING2': DocumentApp.ParagraphHeading.HEADING2,
    'HEADING3': DocumentApp.ParagraphHeading.HEADING3,
    'HEADING4': DocumentApp.ParagraphHeading.HEADING4,
    'HEADING5': DocumentApp.ParagraphHeading.HEADING5,
    'HEADING6': DocumentApp.ParagraphHeading.HEADING6,
    'NORMAL': DocumentApp.ParagraphHeading.NORMAL
  };
  var key = String(name || '').toUpperCase();
  return map[key] || DocumentApp.ParagraphHeading.NORMAL;
}

function escapeRegex_(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Web App entrypoint. POST a JSON body matching applyEdits' payload shape.
 * Returns the same summary object applyEdits produces, or {error: ...} on
 * malformed input. Designed to be deployed as a Web App with:
 *   Execute as: User accessing the web app
 *   Who has access: Anyone within <domain>
 * The script runs as the caller, so it only edits docs they can access.
 */
function doPost(e) {
  try {
    if (!e || !e.postData || !e.postData.contents) {
      return jsonResponse_({ error: 'missing request body' });
    }
    var payload = JSON.parse(e.postData.contents);
    if (!payload || typeof payload !== 'object') {
      return jsonResponse_({ error: 'request body must be a JSON object' });
    }
    var result = applyEdits(payload);
    return jsonResponse_(result);
  } catch (err) {
    return jsonResponse_({ error: String(err && err.message || err) });
  }
}

function jsonResponse_(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
