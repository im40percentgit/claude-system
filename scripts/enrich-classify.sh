#!/usr/bin/env bash
# enrich-classify.sh — Keyword-based complexity classifier for backlog issues.
#
# Purpose: Classify a GitHub issue into simple|medium|complex based on title
# and body keywords. Called by /backlog enrich to determine enrichment depth.
# Designed to be sourceable (provides classify_complexity function) and also
# callable standalone for testing and direct use.
#
# @decision DEC-ENRICH-002
# @title Keyword-based complexity classification in bash
# @status accepted
# @rationale Keyword heuristics are sufficient for v1 (REQ-NOGO-001). No ML,
#   no external dependencies, fast and deterministic. "Simple" = fix/typo/
#   config/bump/rename/update + short body. "Complex" = architecture/redesign/
#   multi-/migrate/security/compliance OR body >500 chars with multiple concerns.
#   Everything else = "medium". Addresses: REQ-P0-001, REQ-NOGO-001.
#
# Usage:
#   Source:     source enrich-classify.sh; classify_complexity "$title" "$body"
#   Standalone: ./enrich-classify.sh "issue title" "issue body"
#   Tests:      ./enrich-classify.sh --test

# classify_complexity <title> <body> -> prints "simple"|"medium"|"complex"
#
# Classification rules (DEC-ENRICH-002):
#   simple:  Title matches simple keywords AND body is short (<100 chars beyond template)
#   complex: Title matches complex keywords OR body is long (>500 chars) with multiple concerns
#   medium:  Everything else
classify_complexity() {
    local title="${1:-}"
    local body="${2:-}"

    local title_lower
    title_lower=$(echo "$title" | tr '[:upper:]' '[:lower:]')

    local body_lower
    body_lower=$(echo "$body" | tr '[:upper:]' '[:lower:]')

    local body_len="${#body}"

    # Complex keywords in title (high-signal indicators of broad scope)
    local complex_title_pattern="architecture|redesign|multi-|migrate|migration|security|compliance|overhaul|refactor|infrastructure|scalab"

    # Complex body indicators: multiple distinct concern areas
    local complex_body_pattern="acceptance criteria|affected files|research|requirements|dependencies|stakeholders|performance|security|compliance"

    # Simple keywords in title (narrow-scope, low-effort tasks)
    local simple_title_pattern="fix typo|typo|fix config|bump|rename|update readme|update changelog|update docs|remove unused|cleanup|clean up|trivial|minor fix|chore"

    # Check complex title first (highest priority signal)
    if echo "$title_lower" | grep -qE "$complex_title_pattern"; then
        echo "complex"
        return 0
    fi

    # Check complex body: long body (>500 chars) with multiple concern keywords
    if [[ "$body_len" -gt 500 ]]; then
        local concern_count
        concern_count=$(echo "$body_lower" | grep -oE "$complex_body_pattern" | sort -u | wc -l)
        if [[ "$concern_count" -ge 2 ]]; then
            echo "complex"
            return 0
        fi
    fi

    # Check simple title keywords (narrow scope, low effort)
    if echo "$title_lower" | grep -qE "$simple_title_pattern"; then
        # Verify body is short enough to confirm simple scope
        if [[ "$body_len" -lt 100 ]]; then
            echo "simple"
            return 0
        fi
    fi

    # Default: medium
    echo "medium"
}

# run_tests — self-test suite covering all tiers
run_tests() {
    local pass=0
    local fail=0

    run_case() {
        local desc="$1"
        local title="$2"
        local body="$3"
        local expected="$4"
        local result
        result=$(classify_complexity "$title" "$body")
        if [[ "$result" == "$expected" ]]; then
            echo "  PASS: $desc -> $result"
            ((pass++)) || true
        else
            echo "  FAIL: $desc -> got '$result', expected '$expected'"
            ((fail++)) || true
        fi
    }

    echo "Running enrich-classify tests..."

    # Simple tier
    run_case "Fix typo in README" \
        "Fix typo in README" \
        "Small typo fix" \
        "simple"

    run_case "Bump dependency version" \
        "Bump lodash from 4.17.20 to 4.17.21" \
        "Security patch" \
        "simple"

    # Medium tier (default)
    run_case "Add rate limiting middleware" \
        "Add rate limiting middleware" \
        "We need rate limiting on the API endpoints." \
        "medium"

    run_case "Implement user avatar upload" \
        "Implement user avatar upload" \
        "Users should be able to upload a profile picture." \
        "medium"

    run_case "Short body no keywords = medium" \
        "Improve error messages in login flow" \
        "Current errors are too generic." \
        "medium"

    # Complex tier - title keyword
    run_case "Redesign auth architecture for multi-tenant" \
        "Redesign auth architecture for multi-tenant support" \
        "Need to overhaul auth system." \
        "complex"

    run_case "Security audit compliance" \
        "Security compliance review for PCI-DSS" \
        "Run the compliance checklist." \
        "complex"

    # Complex tier - long body with multiple concerns
    local long_body
    long_body="This issue covers a large scope of work. Acceptance criteria: must handle 10k rps.
Affected files: auth/, middleware/, routes/.
Research required into OAuth2 patterns.
Security implications must be reviewed.
Dependencies on external auth providers.
Performance benchmarks needed.
Stakeholders: engineering, security, compliance teams.
This will require coordination across multiple teams and careful planning."

    run_case "Long body with multiple concerns = complex" \
        "Overhaul login flow" \
        "$long_body" \
        "complex"

    echo ""
    echo "Results: $pass passed, $fail failed"
    if [[ "$fail" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# --- Entrypoint (standalone mode) ---
# When called directly (not sourced), handle CLI args
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "${1:-}" == "--test" ]]; then
        run_tests
        exit $?
    fi

    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <title> [body]" >&2
        echo "       $0 --test" >&2
        exit 1
    fi

    classify_complexity "${1:-}" "${2:-}"
fi
