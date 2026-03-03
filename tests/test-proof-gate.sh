#!/usr/bin/env bash
# Test proof-status gate bootstrapping and state machine
#
# @decision DEC-TEST-PROOF-GATE-001
# @title Proof-status gate bootstrapping test suite
# @status accepted
# @rationale Tests the proof-status gate state machine which prevents commits
#   without verification while avoiding bootstrap deadlock. Validates that
#   missing .proof-status allows commits (bootstrap path), implementer dispatch
#   activates the gate, and only verified status allows Guardian dispatch.
#   Also validates the guard.sh Check 10 which blocks deletion of active gates.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"

# Ensure tmp directory exists
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

# --- Test 1: Syntax validation ---
run_test "Syntax: guard.sh is valid bash"
if bash -n "$HOOKS_DIR/guard.sh"; then
    pass_test
else
    fail_test "guard.sh has syntax errors"
fi

run_test "Syntax: task-track.sh is valid bash"
if bash -n "$HOOKS_DIR/task-track.sh"; then
    pass_test
else
    fail_test "task-track.sh has syntax errors"
fi

# --- Test 2-9: task-track.sh Gate A (Guardian dispatch) ---
# These tests validate the Guardian gate behavior in task-track.sh

# Helper to run task-track.sh with mock input
run_task_track() {
    local agent_type="$1"
    local proof_file="$2"  # Path to .proof-status or "missing"

    # Create a temp git repo (not meta-repo)
    local TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-pg-repo-XXXXXX")
    git -C "$TEMP_REPO" init > /dev/null 2>&1
    mkdir -p "$TEMP_REPO/.claude"

    # Set up .proof-status if not missing
    if [[ "$proof_file" != "missing" ]]; then
        echo "$proof_file" > "$TEMP_REPO/.claude/.proof-status"
    fi

    # Mock input JSON
    local INPUT_JSON=$(cat <<EOF
{
  "tool_name": "Task",
  "tool_input": {
    "subagent_type": "$agent_type",
    "instructions": "Test task"
  }
}
EOF
)

    # Run hook with mocked environment
    local OUTPUT
    OUTPUT=$(cd "$TEMP_REPO" && \
             CLAUDE_PROJECT_DIR="$TEMP_REPO" \
             echo "$INPUT_JSON" | bash "$HOOKS_DIR/task-track.sh" 2>&1)
    local EXIT_CODE=$?

    # Cleanup - ensure we're not in TEMP_REPO before deleting
    cd "$PROJECT_ROOT"
    rm -rf "$TEMP_REPO"

    # Return output and exit code
    echo "$OUTPUT"
    return $EXIT_CODE
}

run_test "Gate A: Missing .proof-status allows Guardian dispatch (bootstrap)"
OUTPUT=$(run_task_track "guardian" "missing" 2>&1) || true
if echo "$OUTPUT" | grep -q "deny"; then
    fail_test "Guardian blocked when .proof-status missing (should allow)"
else
    pass_test
fi

run_test "Gate A: needs-verification blocks Guardian dispatch"
OUTPUT=$(run_task_track "guardian" "needs-verification|12345" 2>&1) || true
if echo "$OUTPUT" | grep -q "deny" && echo "$OUTPUT" | grep -q "needs-verification"; then
    pass_test
else
    fail_test "Guardian allowed with needs-verification status"
fi

run_test "Gate A: pending blocks Guardian dispatch"
OUTPUT=$(run_task_track "guardian" "pending|12345" 2>&1) || true
if echo "$OUTPUT" | grep -q "deny" && echo "$OUTPUT" | grep -q "pending"; then
    pass_test
else
    fail_test "Guardian allowed with pending status"
fi

run_test "Gate A: verified allows Guardian dispatch"
OUTPUT=$(run_task_track "guardian" "verified|12345" 2>&1) || true
if echo "$OUTPUT" | grep -q "deny"; then
    fail_test "Guardian blocked with verified status (should allow)"
else
    pass_test
fi

# --- Test 10: task-track.sh Gate C (Implementer activation) ---
run_test "Gate C: Implementer dispatch creates needs-verification"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-pg-impl-XXXXXX")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"

INPUT_JSON=$(cat <<'EOF'
{
  "tool_name": "Task",
  "tool_input": {
    "subagent_type": "implementer",
    "instructions": "Test implementation"
  }
}
EOF
)

cd "$TEMP_REPO" && \
    CLAUDE_PROJECT_DIR="$TEMP_REPO" CLAUDE_DIR="$TEMP_REPO/.claude" \
    bash "$HOOKS_DIR/task-track.sh" <<< "$INPUT_JSON" > /dev/null 2>&1

# resolve_proof_file may return a scoped path (.proof-status-{phash}), so check any match
PROOF_FOUND=$(find "$TEMP_REPO/.claude" -maxdepth 1 -name '.proof-status*' -print -quit 2>/dev/null)
if [[ -n "$PROOF_FOUND" ]]; then
    STATUS=$(cut -d'|' -f1 "$PROOF_FOUND")
    if [[ "$STATUS" == "needs-verification" ]]; then
        pass_test
    else
        fail_test "Created .proof-status with wrong status: $STATUS"
    fi
else
    fail_test "Implementer did not create .proof-status"
fi

rm -rf "$TEMP_REPO"

# --- Test 11: gate activation only when missing ---
run_test "Gate C: Implementer does not overwrite existing .proof-status"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-pg-exist-XXXXXX")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"
echo "pending|99999" > "$TEMP_REPO/.claude/.proof-status"

cd "$TEMP_REPO" && \
    CLAUDE_PROJECT_DIR="$TEMP_REPO" \
    echo "$INPUT_JSON" | bash "$HOOKS_DIR/task-track.sh" > /dev/null 2>&1

STATUS=$(cut -d'|' -f1 "$TEMP_REPO/.claude/.proof-status")
TIMESTAMP=$(cut -d'|' -f2 "$TEMP_REPO/.claude/.proof-status")

if [[ "$STATUS" == "pending" && "$TIMESTAMP" == "99999" ]]; then
    pass_test
else
    fail_test "Implementer overwrote existing .proof-status"
fi

rm -rf "$TEMP_REPO"

# --- Tests 12-15: guard.sh Check 6-7 (test-status gate inversion) ---

# Helper to run guard.sh with mock input
run_guard() {
    local command="$1"
    local test_file="$2"  # Path to .test-status or "missing"

    # Create a temp git repo
    local TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-pg-guard-XXXXXX")
    git -C "$TEMP_REPO" init > /dev/null 2>&1
    mkdir -p "$TEMP_REPO/.claude"

    # Set up .test-status if not missing
    if [[ "$test_file" != "missing" ]]; then
        echo "$test_file" > "$TEMP_REPO/.claude/.test-status"
    fi

    # Mock input JSON
    local INPUT_JSON=$(cat <<EOF
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "cd $TEMP_REPO && $command"
  }
}
EOF
)

    # Run hook — cd into temp repo so detect_project_root finds it (not meta-repo)
    local OUTPUT
    OUTPUT=$(cd "$TEMP_REPO" && \
             echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1)
    local EXIT_CODE=$?

    # Cleanup - ensure we're not in TEMP_REPO before deleting
    cd "$PROJECT_ROOT"
    rm -rf "$TEMP_REPO"

    echo "$OUTPUT"
    return $EXIT_CODE
}

run_test "Check 7: Missing .test-status allows commit (bootstrap)"
OUTPUT=$(run_guard "git commit -m test" "missing" 2>&1) || true
if echo "$OUTPUT" | grep -q "deny"; then
    fail_test "Commit blocked when .test-status missing (should allow)"
else
    pass_test
fi

run_test "Check 6: Missing .test-status allows merge (bootstrap)"
OUTPUT=$(run_guard "git merge feature" "missing" 2>&1) || true
if echo "$OUTPUT" | grep -q "deny"; then
    fail_test "Merge blocked when .test-status missing (should allow)"
else
    pass_test
fi

run_test "Check 7: fail test-status blocks commit"
RECENT_TIME=$(date +%s)
OUTPUT=$(run_guard "git commit -m test" "fail|2|$RECENT_TIME|10" 2>&1) || true
if echo "$OUTPUT" | grep -q "deny" && echo "$OUTPUT" | grep -q "failing"; then
    pass_test
else
    fail_test "Commit allowed with failing tests"
fi

run_test "Check 6: fail test-status blocks merge"
RECENT_TIME=$(date +%s)
OUTPUT=$(run_guard "git merge feature" "fail|2|$RECENT_TIME|10" 2>&1) || true
if echo "$OUTPUT" | grep -q "deny" && echo "$OUTPUT" | grep -q "failing"; then
    pass_test
else
    fail_test "Merge allowed with failing tests"
fi

# --- Tests 16-17: guard.sh Check 8 (proof-status gate inversion) ---

# Helper to run guard.sh with proof-status mock
run_guard_proof() {
    local command="$1"
    local proof_file="$2"  # Path to .proof-status or "missing"

    local TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-pg-proof-XXXXXX")
    git -C "$TEMP_REPO" init > /dev/null 2>&1
    mkdir -p "$TEMP_REPO/.claude"

    if [[ "$proof_file" != "missing" ]]; then
        echo "$proof_file" > "$TEMP_REPO/.claude/.proof-status"
    fi

    local INPUT_JSON=$(cat <<EOF
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "cd $TEMP_REPO && $command"
  }
}
EOF
)

    # Run hook — cd into temp repo so detect_project_root finds it (not meta-repo)
    local OUTPUT
    OUTPUT=$(cd "$TEMP_REPO" && \
             echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1)
    local EXIT_CODE=$?

    # Cleanup - ensure we're not in TEMP_REPO before deleting
    cd "$PROJECT_ROOT"
    rm -rf "$TEMP_REPO"

    echo "$OUTPUT"
    return $EXIT_CODE
}

run_test "Check 8: Missing .proof-status allows commit (bootstrap)"
OUTPUT=$(run_guard_proof "git commit -m test" "missing" 2>&1) || true
if echo "$OUTPUT" | grep -q "deny"; then
    fail_test "Commit blocked when .proof-status missing (should allow)"
else
    pass_test
fi

run_test "Check 8: needs-verification blocks commit"
OUTPUT=$(run_guard_proof "git commit -m test" "needs-verification|12345" 2>&1) || true
if echo "$OUTPUT" | grep -q "deny" && echo "$OUTPUT" | grep -q "needs-verification"; then
    pass_test
else
    fail_test "Commit allowed with needs-verification status"
fi

# --- Tests 18-20: guard.sh Check 10 (block .proof-status deletion) ---

run_test "Check 10: Block rm .proof-status when needs-verification"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-pg-del-XXXXXX")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"
echo "needs-verification|12345" > "$TEMP_REPO/.claude/.proof-status"

INPUT_JSON=$(cat <<EOF
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "rm $TEMP_REPO/.claude/.proof-status"
  }
}
EOF
)

OUTPUT=$(cd "$TEMP_REPO" && \
         echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

if echo "$OUTPUT" | grep -q "deny" && echo "$OUTPUT" | grep -q "verification is active"; then
    pass_test
else
    fail_test "Deletion allowed when needs-verification"
fi

cd "$PROJECT_ROOT"  # Ensure we're not in TEMP_REPO before deleting
rm -rf "$TEMP_REPO"

run_test "Check 10: Block rm .proof-status when pending"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-pg-pend-XXXXXX")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"
echo "pending|12345" > "$TEMP_REPO/.claude/.proof-status"

INPUT_JSON=$(cat <<EOF
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "rm $TEMP_REPO/.claude/.proof-status"
  }
}
EOF
)

OUTPUT=$(cd "$TEMP_REPO" && \
         echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

if echo "$OUTPUT" | grep -q "deny" && echo "$OUTPUT" | grep -q "verification is active"; then
    pass_test
else
    fail_test "Deletion allowed when pending"
fi

cd "$PROJECT_ROOT"  # Ensure we're not in TEMP_REPO before deleting
rm -rf "$TEMP_REPO"

run_test "Check 10: Allow rm .proof-status when verified"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-pg-ver-XXXXXX")
git -C "$TEMP_REPO" init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"
echo "verified|12345" > "$TEMP_REPO/.claude/.proof-status"

INPUT_JSON=$(cat <<EOF
{
  "tool_name": "Bash",
  "tool_input": {
    "command": "rm $TEMP_REPO/.claude/.proof-status"
  }
}
EOF
)

OUTPUT=$(cd "$TEMP_REPO" && \
         echo "$INPUT_JSON" | bash "$HOOKS_DIR/guard.sh" 2>&1) || true

if echo "$OUTPUT" | grep -q "deny"; then
    fail_test "Deletion blocked when verified (should allow)"
else
    pass_test
fi

cd "$PROJECT_ROOT"  # Ensure we're not in TEMP_REPO before deleting
rm -rf "$TEMP_REPO"

# --- Tests 21-24: Worktree breadcrumb and resolve_proof_file ---
# These tests validate that Gate C writes breadcrumbs for worktrees,
# that Gate A reads from the worktree proof file via the breadcrumb,
# that stale breadcrumbs fall back to the main CLAUDE_DIR proof file,
# and that resolve_proof_file returns the worktree path when active.
#
# Tests 21 and 22 require repos outside ~/.claude because is_claude_meta_repo()
# exempts all directories under ~/.claude from proof gates. We use /home/j/tmp/
# which is outside the ~/.claude tree and gets cleaned up after each test.
# Tests 23-24 use $PROJECT_ROOT/tmp/ (which is under ~/.claude but those
# tests don't invoke task-track.sh proof gates — they test resolve_proof_file
# directly or use the guardian path after setting up state manually).

# Helper: compute 8-char project hash (mirrors project_hash() in log.sh)
compute_phash() {
    echo "$1" | shasum -a 256 | cut -c1-8
}

# Scratch directory outside ~/.claude for tests that need non-meta-repo git repos.
# These tests use /home/j/tmp/ because all paths under ~/.claude are exempt from
# proof gates via is_claude_meta_repo(), which would skip the code under test.
WT_SCRATCH_BASE="/home/j/tmp/test-proof-gate-$$"
mkdir -p "$WT_SCRATCH_BASE"

# --- Test 21: Gate C writes breadcrumb when in a worktree ---
# Creates a real git worktree via `git worktree add`. detect_project_root
# returns the worktree path (it has its own .git file), while
# `git worktree list --porcelain` returns the main repo as first entry.
# So PROJECT_ROOT != MAIN_WORKTREE, triggering breadcrumb write in Gate C.
# CLAUDE_DIR is set to a temp location so breadcrumb lands there (not ~/.claude).
run_test "Gate C: Implementer dispatch writes breadcrumb when in a worktree"

MAIN21="$WT_SCRATCH_BASE/main21"
mkdir -p "$MAIN21"
git -C "$MAIN21" -c core.hooksPath=/dev/null -c commit.gpgsign=false init > /dev/null 2>&1
git -C "$MAIN21" -c core.hooksPath=/dev/null -c commit.gpgsign=false \
    -c user.email="test@test" -c user.name="test" commit --allow-empty -m "init" > /dev/null 2>&1
WT21="$WT_SCRATCH_BASE/wt21"
git -C "$MAIN21" -c core.hooksPath=/dev/null worktree add "$WT21" -b test-wt > /dev/null 2>&1
mkdir -p "$WT21/.claude"

INPUT_JSON=$(cat <<'EOF'
{
  "tool_name": "Task",
  "tool_input": {
    "subagent_type": "implementer",
    "instructions": "Test implementation"
  }
}
EOF
)

# CLAUDE_DIR is overwritten by get_claude_dir() inside the hook,
# so it always resolves to PROJECT_ROOT/.claude = WT21/.claude
cd "$WT21" && \
    CLAUDE_PROJECT_DIR="$WT21" \
    bash "$HOOKS_DIR/task-track.sh" <<< "$INPUT_JSON" > /dev/null 2>&1
cd "$PROJECT_ROOT"

WT21_PHASH=$(compute_phash "$WT21")
WT21_BREADCRUMB="$WT21/.claude/.active-worktree-path-${WT21_PHASH}"
if [[ -f "$WT21_BREADCRUMB" ]]; then
    WT21_CONTENT=$(cat "$WT21_BREADCRUMB")
    if [[ "$WT21_CONTENT" == "$WT21" ]]; then
        pass_test
    else
        fail_test "Breadcrumb content wrong: expected '$WT21', got '$WT21_CONTENT'"
    fi
else
    fail_test "Breadcrumb not written at $WT21_BREADCRUMB (phash=$WT21_PHASH)"
fi

# --- Test 22: Gate A reads from worktree proof file via breadcrumb ---
# Creates a git repo outside ~/.claude with CLAUDE_DIR set to its .claude/.
# Writes a breadcrumb pointing to a real directory with needs-verification.
# The scoped proof in CLAUDE_DIR has verified, but resolve_proof_file should
# follow the breadcrumb and return the worktree path — causing Guardian deny.
run_test "Gate A: Guardian blocked when worktree proof is needs-verification (breadcrumb active)"

TEMP22="$WT_SCRATCH_BASE/gate22"
mkdir -p "$TEMP22/.claude"
GIT_CONFIG_GLOBAL=/dev/null git -C "$TEMP22" -c core.hooksPath=/dev/null init > /dev/null 2>&1

# Fake worktree directory (doesn't need to be a real git worktree for this test —
# we're testing resolve_proof_file's breadcrumb follow, not Gate C's write)
WT22_DIR="$WT_SCRATCH_BASE/fake-wt22"
mkdir -p "$WT22_DIR/.claude"

PHASH22=$(compute_phash "$TEMP22")
# Breadcrumb in TEMP22's .claude pointing to the fake worktree dir
echo "$WT22_DIR" > "$TEMP22/.claude/.active-worktree-path-${PHASH22}"
# Worktree has needs-verification
echo "needs-verification|12345" > "$WT22_DIR/.claude/.proof-status"
# Scoped proof in main has verified (breadcrumb should take priority)
echo "verified|99999" > "$TEMP22/.claude/.proof-status-${PHASH22}"

INPUT_JSON=$(cat <<EOF
{
  "tool_name": "Task",
  "tool_input": {
    "subagent_type": "guardian",
    "instructions": "Test guardian"
  }
}
EOF
)

OUTPUT=$(cd "$TEMP22" && \
         CLAUDE_PROJECT_DIR="$TEMP22" \
         bash "$HOOKS_DIR/task-track.sh" <<< "$INPUT_JSON" 2>&1) || true
cd "$PROJECT_ROOT"

if echo "$OUTPUT" | grep -q "deny"; then
    pass_test
else
    fail_test "Guardian allowed despite worktree needs-verification (breadcrumb should redirect)"
fi

# Clean up scratch base after tests 21+22
rm -rf "$WT_SCRATCH_BASE"

# --- Test 23: Stale breadcrumb falls back to main CLAUDE_DIR proof file ---
run_test "Gate A: Stale breadcrumb falls back to main .proof-status (allows verified)"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-wt-stale-XXXXXX")
GIT_CONFIG_GLOBAL=/dev/null git -C "$TEMP_REPO" \
    -c core.hooksPath=/dev/null init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"

# Write breadcrumb pointing to a non-existent directory
PHASH=$(compute_phash "$TEMP_REPO")
echo "/nonexistent/worktree/path" > "$TEMP_REPO/.claude/.active-worktree-path-${PHASH}"
# Main scoped proof has verified
echo "verified|12345" > "$TEMP_REPO/.claude/.proof-status-${PHASH}"

INPUT_JSON=$(cat <<EOF
{
  "tool_name": "Task",
  "tool_input": {
    "subagent_type": "guardian",
    "instructions": "Test guardian stale breadcrumb"
  }
}
EOF
)

OUTPUT=$(cd "$TEMP_REPO" && \
         CLAUDE_PROJECT_DIR="$TEMP_REPO" \
         echo "$INPUT_JSON" | bash "$HOOKS_DIR/task-track.sh" 2>&1) || true
cd "$PROJECT_ROOT"

if echo "$OUTPUT" | grep -q "deny"; then
    fail_test "Guardian blocked with stale breadcrumb + verified main status (should allow)"
else
    pass_test
fi

rm -rf "$TEMP_REPO"

# --- Test 24: resolve_proof_file returns worktree path when breadcrumb is active ---
run_test "resolve_proof_file: returns worktree .proof-status when breadcrumb is active"
TEMP_REPO=$(mktemp -d "$PROJECT_ROOT/tmp/test-wt-resolve-XXXXXX")
GIT_CONFIG_GLOBAL=/dev/null git -C "$TEMP_REPO" \
    -c core.hooksPath=/dev/null init > /dev/null 2>&1
mkdir -p "$TEMP_REPO/.claude"

# Simulate worktree by writing breadcrumb + proof file in a subdir
WT_SUBDIR="$TEMP_REPO/fake-wt"
mkdir -p "$WT_SUBDIR/.claude"

PHASH=$(compute_phash "$TEMP_REPO")
echo "$WT_SUBDIR" > "$TEMP_REPO/.claude/.active-worktree-path-${PHASH}"
echo "pending|12345" > "$WT_SUBDIR/.claude/.proof-status"

# Source log.sh and call resolve_proof_file with PROJECT_ROOT = TEMP_REPO
RESULT=$(cd "$TEMP_REPO" && \
         bash -c "
             PROJECT_ROOT='$TEMP_REPO'
             CLAUDE_DIR='$TEMP_REPO/.claude'
             source '$HOOKS_DIR/log.sh'
             resolve_proof_file
         " 2>/dev/null)
cd "$PROJECT_ROOT"

EXPECTED="$WT_SUBDIR/.claude/.proof-status"
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass_test
else
    fail_test "resolve_proof_file returned '$RESULT', expected '$EXPECTED'"
fi

rm -rf "$TEMP_REPO"

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
