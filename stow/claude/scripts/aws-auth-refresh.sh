#!/usr/bin/env bash
# visibility: public
# AWS SSO auth refresh for Claude Code.
# Wired via settings.json: awsAuthRefresh.
# Claude Code invokes this when an AWS API call fails due to expired SSO creds.

set -uo pipefail

PROFILE="${AWS_PROFILE:-${AWS_DEFAULT_PROFILE:-default}}"

if timeout 3 aws sts get-caller-identity --profile "$PROFILE" >/dev/null 2>&1; then
  exit 0
fi

echo "AWS SSO expired for profile: $PROFILE. Triggering login..." >&2
exec aws sso login --profile "$PROFILE"
