#!/usr/bin/env bash
# azure-app-add-password.sh
#
# Mint a new password credential (client secret) on an Azure AD / Entra ID
# application registration, authenticating via OAuth2 client-credentials
# grant as a service principal that owns the target application
# (Application.ReadWrite.OwnedBy scope).
#
# Talks only to two Microsoft-owned endpoints: login.microsoftonline.com
# (token issuance) and graph.microsoft.com (the addPassword call). No other
# network egress, no local persistence of the secret beyond stdout.
#
# Inputs (env vars):
#   TENANT                - Azure AD tenant domain or GUID (required)
#   SP_CLIENT_ID          - client_id of the owning service principal (required)
#   SP_CLIENT_SECRET      - client_secret of the owning service principal (required)
#   TARGET_APP_OBJECT_ID  - object ID (not appId) of the app to add a password to (required)
#   NEW_SECRET_NAME       - displayName for the new password credential (default: pivot-check)
#
# Output: the Graph API JSON response, which includes `secretText` in
#   plaintext exactly once (Graph never returns it again after this call).
#   Treat the output as sensitive: don't paste it into a shared channel,
#   commit it, or leave it in shell history longer than needed.
#
# Example:
#   TENANT=contoso.onmicrosoft.com \
#   SP_CLIENT_ID=11111111-1111-1111-1111-111111111111 \
#   SP_CLIENT_SECRET='...' \
#   TARGET_APP_OBJECT_ID=22222222-2222-2222-2222-222222222222 \
#   bash ~/.claude/scripts/azure-app-add-password.sh

set -euo pipefail

: "${TENANT:?TENANT is required}"
: "${SP_CLIENT_ID:?SP_CLIENT_ID is required}"
: "${SP_CLIENT_SECRET:?SP_CLIENT_SECRET is required}"
: "${TARGET_APP_OBJECT_ID:?TARGET_APP_OBJECT_ID is required}"
NEW_SECRET_NAME="${NEW_SECRET_NAME:-pivot-check}"

token_response=$(curl -sS -X POST "https://login.microsoftonline.com/${TENANT}/oauth2/v2.0/token" \
  -d "grant_type=client_credentials" \
  -d "client_id=${SP_CLIENT_ID}" \
  --data-urlencode "client_secret=${SP_CLIENT_SECRET}" \
  -d "scope=https://graph.microsoft.com/.default")

access_token=$(printf '%s' "$token_response" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if "access_token" not in d:
    print("token request failed: " + json.dumps(d), file=sys.stderr)
    sys.exit(1)
print(d["access_token"])
')

curl -sS -X POST "https://graph.microsoft.com/v1.0/applications/${TARGET_APP_OBJECT_ID}/addPassword" \
  -H "Authorization: Bearer ${access_token}" \
  -H "Content-Type: application/json" \
  -d "{\"passwordCredential\":{\"displayName\":\"${NEW_SECRET_NAME}\"}}" \
  | python3 -m json.tool
