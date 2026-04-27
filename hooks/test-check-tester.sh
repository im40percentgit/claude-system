#!/usr/bin/env bash
# test-check-tester.sh — Unit tests for check-tester.sh auto-verify logic.
#
# Tests three auto-verify scenarios by driving check-tester.sh with fake JSON
# input and a controlled tmp .proof-status. Side-effect functions (audit log,
# git state, trace, statusline) are stubbed via bash function overrides injected
# before the hook sources context-lib.sh/log.sh.
#
# Cases:
#   1. Strict AUTOVERIFY: CLEAN + High + no "Not tested"  → flips to verified
#   2. Strict AUTOVERIFY: CLEAN + High + has "Not tested"  → stays pending
#   3. AUTOVERIFY: CLEAN (hardware-only gap waived) + High + has "Not tested"
#      → flips to verified (relaxed check)
#
# Usage: bash hooks/test-check-tester.sh
# Exit:  0 if all cases pass, 1 on any failure.
#
# @decision DEC-TESTER-002-TEST
# @title Tests for hardware-only gap waiver sentinel (DEC-TESTER-002)
# @status accepted
# @rationale Validates that the hw-waived branch in check-tester.sh correctly
#   flips proof-status to verified when "Not tested" rows are hardware-only gaps,
#   and that the strict path is unaffected. Stubs sourced libs to run without
#   a real git repo or project structure.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HOOK_DIR/check-tester.sh"

PASS=0
FAIL=0

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

make_tmp() {
    local dir
    dir=$(mktemp -d)
    # Minimal .claude/ inside tmp dir
    mkdir -p "$dir/.claude"
    echo "pending|$(date +%s)" > "$dir/.claude/.proof-status"
    echo "$dir"
}

# Build the JSON payload the hook reads from stdin.
# arg1: the tester response body text
make_json() {
    local body="$1"
    # Use jq to safely encode the body as a JSON string value
    printf '{"response":%s}' "$(printf '%s' "$body" | jq -Rs .)"
}

# Run the hook with a given tmp dir and JSON payload.
# Returns 0/1; does NOT exit on failure (we capture the result).
run_hook() {
    local tmp_dir="$1"
    local json="$2"

    # Environment overrides so the hook operates on tmp_dir instead of the
    # real project root, and all side-effect calls are silently no-oped.
    env \
        PROJECT_ROOT="$tmp_dir" \
        CLAUDE_DIR="$tmp_dir/.claude" \
        TRACE_STORE="/dev/null" \
        CLAUDE_SESSION_ID="test-$$" \
        bash -c "
            # Stub sourced libs BEFORE the hook runs them.
            # We export stub functions so the hook's subshell sees them.

            # log.sh stubs
            read_input()         { cat; }
            get_field()          { echo ''; }
            detect_project_root(){ echo \"$tmp_dir\"; }
            get_claude_dir()     { echo \"$tmp_dir/.claude\"; }
            project_hash()       { echo 'testhash'; }
            resolve_proof_file() { echo \"$tmp_dir/.claude/.proof-status\"; }
            log_json()           { :; }
            log_info()           { :; }
            export -f read_input get_field detect_project_root get_claude_dir \
                      project_hash resolve_proof_file log_json log_info

            # context-lib.sh stubs
            get_git_state()         { GIT_BRANCH='main'; GIT_DIRTY_COUNT=0; GIT_WORKTREES=''; GIT_WT_COUNT=0; }
            get_plan_status()       { PLAN_EXISTS=false; PLAN_PHASE=''; PLAN_LIFECYCLE=none; }
            write_statusline_cache(){ :; }
            track_subagent_stop()   { :; }
            detect_active_trace()   { return 1; }
            append_audit()          { :; }
            finalize_trace()        { :; }
            export -f get_git_state get_plan_status write_statusline_cache \
                      track_subagent_stop detect_active_trace append_audit finalize_trace

            # Prevent the hook from re-sourcing the real libs (they would
            # override our stubs). We do this by pre-defining the guard
            # variables used by source guards — but these libs don't have
            # guards, so instead we replace source with a no-op for those
            # two specific files.
            source() {
                local f=\"\$1\"
                case \"\$f\" in
                    */log.sh|*/context-lib.sh) : ;;  # already stubbed above
                    *) builtin source \"\$@\" ;;
                esac
            }
            export -f source

            # Now run the hook with the JSON on stdin
            echo '$json' | bash '$HOOK'
        " 2>/dev/null
}

check_case() {
    local case_num="$1"
    local description="$2"
    local expected_status="$3"   # "verified" or "pending"
    local tmp_dir="$4"
    local json="$5"

    # The hook may exit non-zero (exit 2) when proof is missing — use || true
    run_hook "$tmp_dir" "$json" >/dev/null 2>&1 || true

    local actual_status
    actual_status=$(cut -d'|' -f1 "$tmp_dir/.claude/.proof-status" 2>/dev/null || echo "missing")

    if [[ "$actual_status" == "$expected_status" ]]; then
        echo "PASS  Case $case_num: $description"
        (( PASS++ )) || true
    else
        echo "FAIL  Case $case_num: $description"
        echo "      Expected proof-status='$expected_status', got='$actual_status'"
        (( FAIL++ )) || true
    fi

    rm -rf "$tmp_dir"
}

# --------------------------------------------------------------------------
# Case 1: Strict AUTOVERIFY: CLEAN + **High** + no "Not tested" → verified
# --------------------------------------------------------------------------
TMP=$(make_tmp)
BODY="### Verification Assessment

### Coverage
| Area | Status | Notes |
|------|--------|-------|
| CLI parsing | Fully verified | All flags tested |
| File output  | Fully verified | Output matches |

### What Could Not Be Tested
None

### Confidence Level
**High** — All core paths exercised, output matches expectations.

### Recommended Follow-Up
None

AUTOVERIFY: CLEAN"

JSON=$(make_json "$BODY")
check_case 1 "Strict AUTOVERIFY: CLEAN + High + no Not-tested row => verified" "verified" "$TMP" "$JSON"

# --------------------------------------------------------------------------
# Case 2: Strict AUTOVERIFY: CLEAN + **High** + has "Not tested" → stays pending
# --------------------------------------------------------------------------
TMP=$(make_tmp)
BODY="### Verification Assessment

### Coverage
| Area | Status | Notes |
|------|--------|-------|
| CLI parsing     | Fully verified | All flags tested |
| Live BT hardware | Not tested     | No Ubertooth connected |

### Confidence Level
**High** — Software paths exercised; hardware path not available.

AUTOVERIFY: CLEAN"

JSON=$(make_json "$BODY")
check_case 2 "Strict AUTOVERIFY: CLEAN + High + Not-tested row => stays pending" "pending" "$TMP" "$JSON"

# --------------------------------------------------------------------------
# Case 3: AUTOVERIFY: CLEAN (hardware-only gap waived) + High + "Not tested" → verified
# --------------------------------------------------------------------------
TMP=$(make_tmp)
BODY="### Verification Assessment

### Coverage
| Area | Status | Notes |
|------|--------|-------|
| Subprocess cleanup | Fully verified | Process exits cleanly |
| Live BT hardware   | Not tested     | No Ubertooth connected — hardware-availability gap, post-merge bench test only |

### What Could Not Be Tested
Live Ubertooth hardware path — device not connected. Code up to the hardware boundary is fully exercised.

### Confidence Level
**High** — All software paths verified. Hardware gap explicitly classified as non-blocking.

### Recommended Follow-Up
Post-merge bench test with Ubertooth once hardware is available.

AUTOVERIFY: CLEAN (hardware-only gap waived)"

JSON=$(make_json "$BODY")
check_case 3 "AUTOVERIFY: CLEAN (hardware-only gap waived) + High + Not-tested row => verified" "verified" "$TMP" "$JSON"

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
