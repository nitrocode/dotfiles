#!/bin/bash
# visibility: public
# Stop hook: summarize Claude's last response and speak it via macOS `say`
# Requires: ANTHROPIC_API_KEY env var set, macOS with `say` command

[ -z "${ANTHROPIC_API_KEY:-}" ] && exit 0

# Read the hook payload from stdin
PAYLOAD=$(cat)

# Extract the last assistant message and build the API request
REQUEST_BODY=$(echo "$PAYLOAD" | python3 -c "
import sys, json

data = json.load(sys.stdin)

# Use last_assistant_message directly
msg_text = data.get('last_assistant_message', '')

# If it's a list of content blocks, extract text
if isinstance(msg_text, list):
    texts = []
    for block in msg_text:
        if isinstance(block, str):
            texts.append(block)
        elif isinstance(block, dict) and block.get('type') == 'text':
            texts.append(block.get('text', ''))
    msg_text = ' '.join(texts)

# Skip if too short
if len(msg_text) < 20:
    sys.exit(1)

# Build the API request
print(json.dumps({
    'model': 'claude-haiku-4-5-20251001',
    'max_tokens': 150,
    'messages': [{
        'role': 'user',
        'content': 'In exactly ONE short sentence (under 15 words), give a nudge like \"Hey, the refactor is done\" or \"Take a look, tests are passing now\". Just a brief heads-up to check the result. No markdown:\n\n' + msg_text[:3000]
    }]
}))
" 2>/dev/null)

# Exit if python failed (message too short or no assistant message)
[ -z "$REQUEST_BODY" ] && exit 0

# Call Anthropic API and extract summary
SUMMARY=$(curl -s https://api.anthropic.com/v1/messages \
    -H "content-type: application/json" \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -d "$REQUEST_BODY" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for block in data.get('content', []):
    if block.get('type') == 'text':
        print(block['text'])
        break
" 2>/dev/null)

# Speak it
if [ -n "$SUMMARY" ]; then
    say "$SUMMARY" &
fi
