#!/bin/bash
# Tests for renovate-annotation-check.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$(dirname "$SCRIPT_DIR")"
HOOK="$HOOKS_DIR/renovate-annotation-check.sh"

PASS=0
FAIL=0
FAILED=()

setup_sandbox() {
  SANDBOX=$(mktemp -d)
}
teardown_sandbox() {
  rm -rf "$SANDBOX"
}

invoke_hook() {
  local file="$1"
  printf '{"tool_name":"Edit","tool_response":{"filePath":"%s"}}' "$file" | bash "$HOOK" 2>&1
}

run_test() {
  local name="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1))
    printf "  PASS  %s\n" "$name"
  else
    FAIL=$((FAIL + 1))
    FAILED+=("$name")
    printf "  FAIL  %s\n" "$name"
  fi
}

# --------------------------------------------------------------------------

test_warns_on_unannotated_VERSION_var() {
  setup_sandbox
  local f="$SANDBOX/.github/workflows/ci.yml"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<'YML'
jobs:
  test:
    steps:
      - run: |
          VECTOR_VERSION="0.46.1"
YML
  local out
  out=$(invoke_hook "$f")
  local result=0
  [[ "$out" == *"missing Renovate annotation"* ]] || result=1
  [[ "$out" == *"VECTOR_VERSION"* ]] || result=1
  teardown_sandbox
  return $result
}

test_silent_with_inline_renovate_comment() {
  setup_sandbox
  local f="$SANDBOX/.github/workflows/ci.yml"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<'YML'
jobs:
  test:
    steps:
      - run: |
          VECTOR_VERSION="0.46.1" # renovate: datasource=github-releases depName=vectordotdev/vector
YML
  local out
  out=$(invoke_hook "$f")
  teardown_sandbox
  [[ -z "$out" ]]
}

test_silent_with_comment_before_version() {
  setup_sandbox
  local f="$SANDBOX/.github/workflows/ci.yml"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<'YML'
env:
  # renovate: datasource=github-releases depName=helm/helm
  HELM_VERSION: "3.16.2"
YML
  local out
  out=$(invoke_hook "$f")
  teardown_sandbox
  [[ -z "$out" ]]
}

test_warns_on_unannotated_yaml_version_field() {
  setup_sandbox
  local f="$SANDBOX/.github/workflows/ci.yml"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<'YML'
jobs:
  test:
    steps:
      - uses: azure/setup-helm@dda3372f752e03dde6b3237bc9431cdc2f7a02a2 # v5.0.0
        with:
          version: 3.16.2
YML
  local out
  out=$(invoke_hook "$f")
  teardown_sandbox
  [[ "$out" == *"missing Renovate annotation"* ]]
}

test_skips_sha_pinned_uses_lines() {
  setup_sandbox
  local f="$SANDBOX/.github/workflows/ci.yml"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<'YML'
jobs:
  test:
    steps:
      - uses: actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd # v6.0.2
YML
  local out
  out=$(invoke_hook "$f")
  teardown_sandbox
  [[ -z "$out" ]]
}

test_skips_non_in_scope_files() {
  setup_sandbox
  local f="$SANDBOX/values.yaml"
  cat > "$f" <<'YML'
vector:
  image:
    tag: 0.46.1
YML
  local out
  out=$(invoke_hook "$f")
  teardown_sandbox
  [[ -z "$out" ]]
}

test_skips_pip_requirements_files() {
  setup_sandbox
  local f="$SANDBOX/requirements-validation.txt"
  echo "PyYAML==6.0.2" > "$f"
  local out
  out=$(invoke_hook "$f")
  teardown_sandbox
  [[ -z "$out" ]]
}

test_warns_on_dockerfile_ARG_version() {
  setup_sandbox
  local f="$SANDBOX/Dockerfile"
  cat > "$f" <<'DOCKER'
FROM alpine:3.20
ARG ATMOS_VERSION=1.168.0
DOCKER
  local out
  out=$(invoke_hook "$f")
  teardown_sandbox
  [[ "$out" == *"missing Renovate annotation"* ]] && [[ "$out" == *"ATMOS_VERSION"* ]]
}

test_silent_dockerfile_with_inline_annotation() {
  setup_sandbox
  local f="$SANDBOX/Dockerfile"
  cat > "$f" <<'DOCKER'
ARG ATMOS_VERSION=1.168.0 # renovate: datasource=github-releases depName=cloudposse/atmos
DOCKER
  local out
  out=$(invoke_hook "$f")
  teardown_sandbox
  [[ -z "$out" ]]
}

test_warns_on_shell_script_version_flag() {
  setup_sandbox
  local f="$SANDBOX/install.sh"
  cat > "$f" <<'SH'
#!/bin/bash
helm plugin install https://github.com/x/y --version v0.5.1
SH
  local out
  out=$(invoke_hook "$f")
  teardown_sandbox
  [[ "$out" == *"missing Renovate annotation"* ]]
}

# --------------------------------------------------------------------------

run_test "warn on VERSION env var without annotation"   test_warns_on_unannotated_VERSION_var
run_test "silent with inline renovate comment"          test_silent_with_inline_renovate_comment
run_test "silent with comment-before-version"           test_silent_with_comment_before_version
run_test "warn on unannotated yaml version field"       test_warns_on_unannotated_yaml_version_field
run_test "skip SHA-pinned uses: lines"                  test_skips_sha_pinned_uses_lines
run_test "skip non-in-scope files (random yaml)"        test_skips_non_in_scope_files
run_test "skip pip requirements files"                  test_skips_pip_requirements_files
run_test "warn on Dockerfile ARG version"               test_warns_on_dockerfile_ARG_version
run_test "silent on Dockerfile with inline annotation"  test_silent_dockerfile_with_inline_annotation
run_test "warn on shell --version flag"                 test_warns_on_shell_script_version_flag

echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
