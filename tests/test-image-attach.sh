#!/usr/bin/env bash
# tests/test-image-attach.sh — Test suite for image attachment functions in todo.sh
#
# @decision DEC-TEST-IMAGE-ATTACH-001
# @title Test suite for save_image, upload_image_gist, cmd_images, cmd_attach
# @status accepted
# @rationale Tests the image attachment pipeline in todo.sh: local save, gist upload
#   URL fix (DEC-TODO-GIST-URL-001), local cache listing, and full e2e attach flow.
#   Non-live tests (save_image, cmd_images) run unconditionally. Live tests
#   (upload_image_gist, cmd_attach --gist) require TEST_GIST_LIVE=1 to avoid
#   incidental GitHub API calls in CI. Follows the run_test/pass_test/fail_test
#   pattern from test-proof-gate.sh for consistency.
#
#   Sourcing strategy: todo.sh has no source-guard — it runs require_gh, resolves
#   repos, and dispatches on "$1" at the bottom when sourced. We suppress that
#   output by sourcing with stdout redirected to /dev/null, then calling the
#   target function in a second command where stdout IS captured. Functions are
#   exported into the subshell environment via a shared source-and-call pattern.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"
TODO_SH="$SCRIPTS_DIR/todo.sh"

# Ensure tmp directory exists (Sacred Practice #3 — no /tmp/)
mkdir -p "$PROJECT_ROOT/tmp"

# Track test results
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "Running: $test_name"
}

pass_test() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  ✓ PASS"
}

fail_test() {
    local reason="$1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  ✗ FAIL: $reason"
}

# --- Helpers ---

# Create a minimal valid PNG (1x1 pixel) as a test fixture.
create_test_image() {
    local dest="$1"
    # Minimal 1x1 white PNG — raw bytes
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82' > "$dest"
}

# Source todo.sh and call a function in a single subshell.
# Usage: call_todo_fn <work_dir> <fn_name> [args...]
# - Stubs gh so require_gh passes without real auth
# - Redirects the source-time dispatcher output to /dev/null
# - Captures only the target function's stdout
# - Sets TODO_IMAGES_DIR to $work_dir/images and HOME to $work_dir for isolation
call_todo_fn() {
    local work_dir="$1"
    local fn_name="$2"
    shift 2
    local fn_args=("$@")

    (
        export TODO_IMAGES_DIR="$work_dir/images"
        export HOME="$work_dir"
        export GLOBAL_REPO="testuser/cc-todos"
        export CONFIG_REPO="testuser/claude-system"

        gh() { :; }
        export -f gh

        # Source todo.sh suppressing the dispatcher output (usage/help block),
        # then immediately call the target function.
        set +e
        source "$TODO_SH" >/dev/null 2>/dev/null || true
        set -e

        "${fn_name}" "${fn_args[@]}"
    )
}

# Same as call_todo_fn but also injects override functions and a custom gh stub.
# Usage: call_todo_fn_with_stubs <work_dir> <gh_stub_body> <fn_name> [args...]
# gh_stub_body: a function body string for the gh() stub
call_todo_fn_with_stubs() {
    local work_dir="$1"
    local gh_stub_body="$2"
    local fn_name="$3"
    shift 3
    local fn_args=("$@")

    (
        export TODO_IMAGES_DIR="$work_dir/images"
        export HOME="$work_dir"
        export GLOBAL_REPO="testuser/cc-todos"
        export CONFIG_REPO="testuser/claude-system"

        eval "gh() { $gh_stub_body; }"
        export -f gh

        set +e
        source "$TODO_SH" >/dev/null 2>/dev/null || true
        set -e

        # Override repo detection helpers
        get_repo_name() { echo "testowner/testrepo"; }
        is_git_repo() { return 0; }

        "${fn_name}" "${fn_args[@]}"
    )
}

# --- Test 1: Syntax validation ---

run_test "Syntax: todo.sh is valid bash"
if bash -n "$TODO_SH"; then
    pass_test
else
    fail_test "todo.sh has syntax errors"
fi

# --- Test 2: save_image — local file copy assertion ---

run_test "save_image: copies file to correct dest_dir with timestamp prefix"

WORK_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-imgattach-XXXXXX")
TEST_IMG="$WORK_DIR/test-screenshot.png"
create_test_image "$TEST_IMG"
mkdir -p "$WORK_DIR/images"

SAVED_PATH=$(call_todo_fn "$WORK_DIR" save_image \
    "$TEST_IMG" "testowner-testrepo" "42" 2>/dev/null) || true

# todo.sh sets TODO_IMAGES_DIR="$HOME/.claude/todo-images" at parse time,
# so with HOME=$WORK_DIR the effective path is $WORK_DIR/.claude/todo-images
EXPECTED_DIR="$WORK_DIR/.claude/todo-images/testowner-testrepo/42"

if [[ -n "$SAVED_PATH" && -f "$SAVED_PATH" ]]; then
    ACTUAL_DIR=$(dirname "$SAVED_PATH")
    if [[ "$ACTUAL_DIR" == "$EXPECTED_DIR" ]]; then
        BASENAME=$(basename "$SAVED_PATH")
        if echo "$BASENAME" | grep -qE '^[0-9]+-test-screenshot\.png$'; then
            pass_test
        else
            fail_test "Filename does not have expected timestamp prefix: $BASENAME"
        fi
    else
        fail_test "File saved to wrong directory: $ACTUAL_DIR (expected $EXPECTED_DIR)"
    fi
else
    fail_test "save_image returned empty path or file does not exist: '$SAVED_PATH'"
fi

rm -rf "$WORK_DIR"

# --- Test 3: save_image — missing source file returns error ---

run_test "save_image: returns error when source image does not exist"

WORK_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-imgattach-XXXXXX")
mkdir -p "$WORK_DIR/images"

ERR_OUTPUT=$(call_todo_fn "$WORK_DIR" save_image \
    "$WORK_DIR/nonexistent.png" "owner-repo" "1" 2>&1) || true

if echo "$ERR_OUTPUT" | grep -q "ERROR: Image not found"; then
    pass_test
else
    fail_test "Expected 'ERROR: Image not found' in output, got: $ERR_OUTPUT"
fi

rm -rf "$WORK_DIR"

# --- Test 4: cmd_images — listing from local cache ---

run_test "cmd_images: lists cached images for an issue"

WORK_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-imgattach-XXXXXX")

# Pre-populate the cache directory as save_image would.
# todo.sh resolves TODO_IMAGES_DIR as $HOME/.claude/todo-images at parse time,
# so with HOME=$WORK_DIR the effective path is $WORK_DIR/.claude/todo-images.
CACHE_DIR="$WORK_DIR/.claude/todo-images/testowner-testrepo/7"
mkdir -p "$CACHE_DIR"
echo "fake" > "$CACHE_DIR/1700000000-screenshot.png"
echo "fake" > "$CACHE_DIR/1700000001-diagram.png"

OUTPUT=$(call_todo_fn_with_stubs "$WORK_DIR" ":" cmd_images "7" 2>&1) || true

if echo "$OUTPUT" | grep -q "1700000000-screenshot.png" && \
   echo "$OUTPUT" | grep -q "1700000001-diagram.png"; then
    pass_test
else
    fail_test "cmd_images output missing expected filenames. Got: $OUTPUT"
fi

rm -rf "$WORK_DIR"

# --- Test 5: cmd_images — no images returns graceful message ---

run_test "cmd_images: prints 'No images' when cache is empty for issue"

WORK_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-imgattach-XXXXXX")
# No pre-populated cache — $WORK_DIR/.claude/todo-images/testowner-testrepo/99 won't exist

OUTPUT=$(call_todo_fn_with_stubs "$WORK_DIR" ":" cmd_images "99" 2>&1) || true

if echo "$OUTPUT" | grep -qi "no images"; then
    pass_test
else
    fail_test "Expected 'No images' message, got: $OUTPUT"
fi

rm -rf "$WORK_DIR"

# --- Test 6: upload_image_gist URL fix — stubbed gh/jq ---
# Verifies the fixed function uses gh gist view --json files to get rawUrl.

run_test "upload_image_gist: uses gh gist view API to get rawUrl (stubbed)"

WORK_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-imgattach-XXXXXX")
TEST_IMG="$WORK_DIR/attach.png"
create_test_image "$TEST_IMG"
mkdir -p "$WORK_DIR/images"

EXPECTED_URL="https://gist.githubusercontent.com/testuser/abc123/raw/deadbeef/attach.png"

GH_STUB=$(cat <<'STUB'
case "$1" in
    gist)
        case "$2" in
            create) echo "https://gist.github.com/testuser/abc123" ;;
            view)   echo '{"files":{"attach.png":{"filename":"attach.png","rawUrl":"https://gist.githubusercontent.com/testuser/abc123/raw/deadbeef/attach.png"}}}' ;;
        esac ;;
esac
STUB
)

OUTPUT=$(call_todo_fn_with_stubs "$WORK_DIR" "$GH_STUB" upload_image_gist \
    "$TEST_IMG" "Test attachment" 2>/dev/null) || true

if [[ "$OUTPUT" == "$EXPECTED_URL" ]]; then
    pass_test
else
    fail_test "Expected '$EXPECTED_URL', got: '$OUTPUT'"
fi

rm -rf "$WORK_DIR"

# --- Test 7: upload_image_gist — empty rawUrl falls back gracefully ---

run_test "upload_image_gist: falls back gracefully when rawUrl extraction returns empty"

WORK_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-imgattach-XXXXXX")
TEST_IMG="$WORK_DIR/attach.png"
create_test_image "$TEST_IMG"
mkdir -p "$WORK_DIR/images"

GH_STUB_EMPTY=$(cat <<'STUB'
case "$1" in
    gist)
        case "$2" in
            create) echo "https://gist.github.com/testuser/abc123" ;;
            view)   echo '{"files":{}}' ;;
        esac ;;
esac
STUB
)

OUTPUT=$(call_todo_fn_with_stubs "$WORK_DIR" "$GH_STUB_EMPTY" upload_image_gist \
    "$TEST_IMG" "Test attachment" 2>&1) || true

if echo "$OUTPUT" | grep -q "WARNING: Could not extract raw URL"; then
    pass_test
else
    fail_test "Expected fallback WARNING message, got: $OUTPUT"
fi

rm -rf "$WORK_DIR"

# --- Live tests (gated by TEST_GIST_LIVE=1) ---

if [[ "${TEST_GIST_LIVE:-0}" == "1" ]]; then

    run_test "LIVE upload_image_gist: creates gist and returns valid rawUrl"

    WORK_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-imgattach-live-XXXXXX")
    TEST_IMG="$WORK_DIR/live-test.png"
    create_test_image "$TEST_IMG"
    mkdir -p "$WORK_DIR/images"

    RAW_URL=$(call_todo_fn "$WORK_DIR" upload_image_gist \
        "$TEST_IMG" "CI test attachment — safe to delete" 2>/dev/null) || true

    if echo "$RAW_URL" | grep -qE '^https://gist\.githubusercontent\.com/.+/raw/.+/live-test\.png$'; then
        pass_test
        echo "  Raw URL: $RAW_URL"
        # Clean up the test gist
        GIST_ID=$(echo "$RAW_URL" | awk -F'/' '{print $6}')
        gh gist delete "$GIST_ID" 2>/dev/null || true
    else
        fail_test "Returned URL does not match expected pattern: $RAW_URL"
    fi

    rm -rf "$WORK_DIR"

    # --- Live Test: cmd_attach --gist e2e ---

    run_test "LIVE cmd_attach --gist: saves locally and posts comment with markdown image"

    if [[ -z "${TEST_ATTACH_REPO:-}" || -z "${TEST_ATTACH_ISSUE:-}" ]]; then
        fail_test "Set TEST_ATTACH_REPO=owner/repo and TEST_ATTACH_ISSUE=<number> to run this test"
    else
        WORK_DIR=$(mktemp -d "$PROJECT_ROOT/tmp/test-imgattach-e2e-XXXXXX")
        TEST_IMG="$WORK_DIR/e2e-attach.png"
        create_test_image "$TEST_IMG"
        mkdir -p "$WORK_DIR/images"

        # For the e2e test we use real gh, but inject our test repo/issue
        E2E_STUB=$(cat <<STUB
# Pass through to real gh for live test
command gh "\$@"
STUB
)
        OUTPUT=$(
            export TODO_IMAGES_DIR="$WORK_DIR/images"
            export HOME="$WORK_DIR"
            export GLOBAL_REPO="$TEST_ATTACH_REPO"

            set +e
            source "$TODO_SH" >/dev/null 2>/dev/null || true
            set -e

            get_repo_name() { echo "$TEST_ATTACH_REPO"; }
            is_git_repo() { return 0; }

            cmd_attach "$TEST_ATTACH_ISSUE" "$TEST_IMG" --gist 2>&1
        ) || true

        if echo "$OUTPUT" | grep -q "Uploaded:" && echo "$OUTPUT" | grep -q "Saved:"; then
            pass_test
            echo "  $OUTPUT"
        else
            fail_test "cmd_attach output missing expected 'Uploaded:' or 'Saved:'. Got: $OUTPUT"
        fi

        rm -rf "$WORK_DIR"
    fi

else
    echo ""
    echo "Skipping live tests (set TEST_GIST_LIVE=1 to run gist API tests)"
fi

# --- Summary ---
echo ""
echo "=========================================="
echo "Test Results: $TESTS_PASSED/$TESTS_RUN passed"
echo "=========================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
    echo "FAILED: $TESTS_FAILED tests failed"
    exit 1
else
    echo "SUCCESS: All tests passed"
    exit 0
fi
