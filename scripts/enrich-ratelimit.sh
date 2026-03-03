#!/usr/bin/env bash
# enrich-ratelimit.sh — Rate limiting for complex backlog enrichments.
#
# Purpose: Track and limit complex enrichment runs to prevent runaway API costs.
# Stores a TSV audit log of every enrichment run. Before a complex enrichment,
# the caller checks whether the limit has been reached for the current hour window.
#
# Log file: ~/.config/cc-todos/enrich-log.tsv
# Format:   timestamp<TAB>issue_number<TAB>tier<TAB>duration_seconds
#
# @decision DEC-ENRICH-003
# @title TSV-based rate limiting for complex enrichments
# @status accepted
# @rationale Simple, auditable, zero-dependency approach. A flat TSV file is
#   human-readable, trivially parseable with awk, and requires no daemon or
#   external state. Max 3 complex enrichments per hour is generous enough for
#   real workflows but prevents runaway deep-research invocations.
#   Addresses: REQ-P0-007.
#
# Usage:
#   Source:     source enrich-ratelimit.sh
#               check_rate_limit        # returns 0=ok, 1=over limit
#               log_enrichment <issue#> <tier> <duration_seconds>
#               get_recent_count        # prints count of complex runs last hour
#   Tests:      ./enrich-ratelimit.sh --test

ENRICH_LOG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cc-todos"
ENRICH_LOG_FILE="$ENRICH_LOG_DIR/enrich-log.tsv"
ENRICH_RATE_LIMIT=3       # max complex enrichments per rolling hour
ENRICH_WINDOW_SECS=3600   # 1 hour in seconds

# get_recent_count — Count complex enrichments in the last ENRICH_WINDOW_SECS.
# Prints an integer. Handles missing log file gracefully (prints 0).
get_recent_count() {
    if [[ ! -f "$ENRICH_LOG_FILE" ]]; then
        echo 0
        return 0
    fi

    local now
    now=$(date +%s)
    local cutoff=$(( now - ENRICH_WINDOW_SECS ))

    # TSV columns: 1=timestamp 2=issue_number 3=tier 4=duration
    awk -F'\t' -v cutoff="$cutoff" \
        '$1 >= cutoff && $3 == "complex" { count++ } END { print count+0 }' \
        "$ENRICH_LOG_FILE"
}

# check_rate_limit — Returns 0 if under the limit, 1 if at or over the limit.
# Callers should check the return code: 0=proceed, 1=blocked.
check_rate_limit() {
    local count
    count=$(get_recent_count)
    if [[ "$count" -ge "$ENRICH_RATE_LIMIT" ]]; then
        return 1
    fi
    return 0
}

# log_enrichment <issue_number> <tier> <duration_seconds>
# Appends one TSV line to the enrichment log. Creates the log directory if needed.
log_enrichment() {
    local issue_number="${1:-0}"
    local tier="${2:-unknown}"
    local duration="${3:-0}"

    mkdir -p "$ENRICH_LOG_DIR"
    printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$issue_number" "$tier" "$duration" \
        >> "$ENRICH_LOG_FILE"
}

# --- Self-test suite ---
run_tests() {
    local pass=0
    local fail=0

    # Use a temp log file so tests never touch the real log
    local orig_log="$ENRICH_LOG_FILE"
    local test_log
    test_log=$(mktemp)
    ENRICH_LOG_FILE="$test_log"

    run_case() {
        local desc="$1"
        local expected="$2"
        local actual="$3"
        if [[ "$actual" == "$expected" ]]; then
            echo "  PASS: $desc"
            ((pass++)) || true
        else
            echo "  FAIL: $desc — got '$actual', expected '$expected'"
            ((fail++)) || true
        fi
    }

    echo "Running enrich-ratelimit tests..."

    # Test 1: Empty log -> count is 0 and rate limit not exceeded
    > "$test_log"
    run_case "Empty log: get_recent_count returns 0" \
        "0" "$(get_recent_count)"

    check_rate_limit; local rc=$?
    run_case "Empty log: check_rate_limit returns 0 (ok to proceed)" \
        "0" "$rc"

    # Test 2: 3 recent complex entries -> at limit, check_rate_limit returns 1
    local now
    now=$(date +%s)
    printf '%s\tcomplex_issue\tcomplex\t5\n' "$now" >> "$test_log"
    printf '%s\tcomplex_issue\tcomplex\t5\n' "$now" >> "$test_log"
    printf '%s\tcomplex_issue\tcomplex\t5\n' "$now" >> "$test_log"
    run_case "3 recent complex entries: get_recent_count returns 3" \
        "3" "$(get_recent_count)"

    check_rate_limit; rc=$?
    run_case "3 recent complex entries: check_rate_limit returns 1 (blocked)" \
        "1" "$rc"

    # Test 3: Old entries (2+ hours ago) are not counted
    > "$test_log"
    local old_ts=$(( now - 7300 ))   # ~2 hours ago, outside the 1-hour window
    printf '%s\t42\tcomplex\t5\n' "$old_ts" >> "$test_log"
    printf '%s\t42\tcomplex\t5\n' "$old_ts" >> "$test_log"
    printf '%s\t42\tcomplex\t5\n' "$old_ts" >> "$test_log"
    run_case "3 old entries (outside window): get_recent_count returns 0" \
        "0" "$(get_recent_count)"

    check_rate_limit; rc=$?
    run_case "3 old entries: check_rate_limit returns 0 (not blocked)" \
        "0" "$rc"

    # Test 4: Non-complex tiers (medium, simple) are not counted toward limit
    > "$test_log"
    printf '%s\t55\tmedium\t3\n' "$now" >> "$test_log"
    printf '%s\t56\tsimple\t1\n' "$now" >> "$test_log"
    printf '%s\t57\tmedium\t2\n' "$now" >> "$test_log"
    run_case "3 non-complex entries: get_recent_count returns 0" \
        "0" "$(get_recent_count)"

    # Test 5: log_enrichment creates a valid TSV line
    > "$test_log"
    log_enrichment 99 complex 42
    local line_count
    line_count=$(wc -l < "$test_log" | tr -d ' ')
    run_case "log_enrichment writes exactly 1 line" \
        "1" "$line_count"

    local logged_tier
    logged_tier=$(awk -F'\t' 'NR==1{print $3}' "$test_log")
    run_case "log_enrichment records correct tier" \
        "complex" "$logged_tier"

    # Restore original log path and clean up
    ENRICH_LOG_FILE="$orig_log"
    rm -f "$test_log"

    echo ""
    echo "Results: $pass passed, $fail failed"
    if [[ "$fail" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# --- Entrypoint (standalone mode) ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "${1:-}" == "--test" ]]; then
        run_tests
        exit $?
    fi

    echo "Usage: source $0  (to use check_rate_limit, log_enrichment, get_recent_count)"
    echo "       $0 --test  (to run self-tests)"
    exit 0
fi
