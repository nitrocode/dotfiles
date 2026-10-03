#!/usr/bin/env bash
# Audit AWS IAM Identity Center groups for ones with no account/permission-set
# assignment (an "AccountAssignment" always pairs an account + permission set,
# so zero assignments means neither is attached).
# Reads from the org's Identity Center via the readonly-root profile.
# Output: TSV (group_id, group_name, status).
#
# Usage: ~/.claude/scripts/audit-aws-idc-unassigned-groups.sh
# Example: audit-aws-idc-unassigned-groups.sh | column -t -s$'\t'
#          audit-aws-idc-unassigned-groups.sh | awk -F'\t' '$3 == "NO_ASSIGNMENT"'

set -euo pipefail

PROFILE="${AWS_PROFILE_OVERRIDE:-readonly-root}"
REGION="${AWS_REGION_OVERRIDE:-us-east-1}"

instance_json=$(aws --profile "$PROFILE" --region "$REGION" sso-admin list-instances --output json)
INSTANCE_ARN=$(echo "$instance_json" | jq -r '.Instances[0].InstanceArn // empty')
IDSTORE=$(echo "$instance_json" | jq -r '.Instances[0].IdentityStoreId // empty')

if [[ -z "$INSTANCE_ARN" || -z "$IDSTORE" ]]; then
  echo "ERROR: could not resolve IAM Identity Center instance via profile '$PROFILE'." >&2
  exit 1
fi

printf "group_id\tgroup_name\tstatus\n"

next_token=""
while :; do
  if [[ -z "$next_token" ]]; then
    page=$(aws --profile "$PROFILE" --region "$REGION" identitystore list-groups \
      --identity-store-id "$IDSTORE" --output json)
  else
    page=$(aws --profile "$PROFILE" --region "$REGION" identitystore list-groups \
      --identity-store-id "$IDSTORE" --starting-token "$next_token" --output json)
  fi

  while IFS=$'\t' read -r group_id group_name; do
    [[ -z "$group_id" ]] && continue

    assignments=$(aws --profile "$PROFILE" --region "$REGION" sso-admin list-account-assignments-for-principal \
      --instance-arn "$INSTANCE_ARN" \
      --principal-id "$group_id" \
      --principal-type GROUP \
      --output json)

    count=$(echo "$assignments" | jq -r '.AccountAssignments | length')

    if [[ "$count" -eq 0 ]]; then
      printf "%s\t%s\t%s\n" "$group_id" "$group_name" "NO_ASSIGNMENT"
    else
      printf "%s\t%s\t%s\n" "$group_id" "$group_name" "ASSIGNED"
    fi
  done < <(echo "$page" | jq -r '.Groups[] | [.GroupId, .DisplayName] | @tsv')

  next_token=$(echo "$page" | jq -r '.NextToken // empty')
  [[ -z "$next_token" ]] && break
done
