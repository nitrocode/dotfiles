#!/bin/bash
# Unit tests for $CLAUDE_CONFIG_DIR/scripts/audit-aws-idc-unassigned-groups.sh.
# Mocks `aws` via a PATH shim so no real AWS API call happens.
set -u
# shellcheck source=../../hooks/tests/_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

SCRIPT="$CLAUDE_CONFIG_DIR/scripts/audit-aws-idc-unassigned-groups.sh"
echo "test-audit-aws-idc-unassigned-groups.sh:"

setup_bin() {
  BINDIR=$(mktemp -d)
  export PATH="$BINDIR:$PATH"
}

teardown_bin() {
  rm -rf "$BINDIR"
}

# write_aws_stub <groups-pages-json-array> <assignments-by-group-id-json-object>
# groups-pages: array of pages, each page is {"Groups":[...], "NextToken": "<index of next page as string>"|null}
# On the first list-groups call (no --starting-token), page 0 is returned. A page's
# NextToken, when non-null, is the string index of the next page to serve.
# assignments: object mapping group_id -> array of AccountAssignments (possibly empty)
write_aws_stub() {
  local pages_json="$1" assignments_json="$2"
  cat >"$BINDIR/aws" <<EOF
#!/bin/bash
PAGES='$pages_json'
ASSIGNMENTS='$assignments_json'

starting_token=""
prev=""
for arg in "\$@"; do
  if [[ "\$prev" == "--starting-token" ]]; then
    starting_token="\$arg"
  fi
  prev="\$arg"
done

if [[ "\$*" == *"sso-admin list-instances"* ]]; then
  echo '{"Instances":[{"InstanceArn":"arn:aws:sso:::instance/ssoins-test","IdentityStoreId":"d-testid"}]}'
  exit 0
fi

if [[ "\$*" == *"identitystore list-groups"* ]]; then
  idx="\${starting_token:-0}"
  echo "\$PAGES" | jq --argjson i "\$idx" '.[\$i]'
  exit 0
fi

if [[ "\$*" == *"sso-admin list-account-assignments-for-principal"* ]]; then
  gid=""
  prev2=""
  for arg in "\$@"; do
    if [[ "\$prev2" == "--principal-id" ]]; then
      gid="\$arg"
    fi
    prev2="\$arg"
  done
  echo "\$ASSIGNMENTS" | jq --arg g "\$gid" '{"AccountAssignments": (.[\$g] // [])}'
  exit 0
fi

echo "unmocked aws call: \$*" >&2
exit 1
EOF
  chmod +x "$BINDIR/aws"
}

test_mixed_assigned_and_unassigned() {
  setup_bin
  write_aws_stub \
    '[{"Groups":[{"GroupId":"g1","DisplayName":"Assigned-Group"},{"GroupId":"g2","DisplayName":"Orphan-Group"}],"NextToken":null}]' \
    '{"g1":[{"AccountId":"111","PermissionSetArn":"arn:aws:sso:::permissionSet/ps-1"}],"g2":[]}'
  local out
  out=$("$SCRIPT" 2>&1); local code=$?
  teardown_bin
  [[ $code -eq 0 ]] \
    && assert_contains "$out" $'g1\tAssigned-Group\tASSIGNED' \
    && assert_contains "$out" $'g2\tOrphan-Group\tNO_ASSIGNMENT'
}

test_all_assigned() {
  setup_bin
  write_aws_stub \
    '[{"Groups":[{"GroupId":"g1","DisplayName":"Group-One"}],"NextToken":null}]' \
    '{"g1":[{"AccountId":"111","PermissionSetArn":"arn:aws:sso:::permissionSet/ps-1"}]}'
  local out
  out=$("$SCRIPT" 2>&1); local code=$?
  teardown_bin
  [[ $code -eq 0 ]] && assert_contains "$out" "ASSIGNED" && ! [[ "$out" == *"NO_ASSIGNMENT"* ]]
}

test_all_unassigned() {
  setup_bin
  write_aws_stub \
    '[{"Groups":[{"GroupId":"g1","DisplayName":"Group-One"},{"GroupId":"g2","DisplayName":"Group-Two"}],"NextToken":null}]' \
    '{"g1":[],"g2":[]}'
  local out
  out=$("$SCRIPT" 2>&1); local code=$?
  teardown_bin
  local no_assignment_count
  no_assignment_count=$(printf '%s\n' "$out" | grep -c "NO_ASSIGNMENT")
  [[ $code -eq 0 && "$no_assignment_count" -eq 2 ]]
}

test_paginates_group_list() {
  setup_bin
  write_aws_stub \
    '[{"Groups":[{"GroupId":"g1","DisplayName":"Page-One-Group"}],"NextToken":"1"},{"Groups":[{"GroupId":"g2","DisplayName":"Page-Two-Group"}],"NextToken":null}]' \
    '{"g1":[],"g2":[{"AccountId":"222","PermissionSetArn":"arn:aws:sso:::permissionSet/ps-2"}]}'
  local out
  out=$("$SCRIPT" 2>&1); local code=$?
  teardown_bin
  [[ $code -eq 0 ]] \
    && assert_contains "$out" "Page-One-Group" \
    && assert_contains "$out" "Page-Two-Group"
}

test_missing_instance_fails_loud() {
  setup_bin
  cat >"$BINDIR/aws" <<'EOF'
#!/bin/bash
if [[ "$*" == *"sso-admin list-instances"* ]]; then
  echo '{"Instances":[]}'
  exit 0
fi
echo "unmocked aws call: $*" >&2
exit 1
EOF
  chmod +x "$BINDIR/aws"
  local out
  out=$("$SCRIPT" 2>&1); local code=$?
  teardown_bin
  [[ $code -eq 1 ]] && assert_contains "$out" "could not resolve IAM Identity Center instance"
}

run_test "flags unassigned groups, keeps assigned ones" test_mixed_assigned_and_unassigned
run_test "all groups assigned -> no NO_ASSIGNMENT rows" test_all_assigned
run_test "all groups unassigned -> flags all" test_all_unassigned
run_test "paginates through multiple group-list pages" test_paginates_group_list
run_test "fails loud when instance cannot be resolved" test_missing_instance_fails_loud

print_summary
