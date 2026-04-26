#!/usr/bin/env bash
# lib-live-e2e.sh — Shared library for live E2E evidence classification.
# Source this file from hooks that need to classify changes or read/write
# the evidence_kind field of .test-status.
#
#   source "$(dirname "$0")/lib-live-e2e.sh"
#
# Exports:
#   classify_change <file_path>              → runtime|text|test|unknown
#   classify_session_changes <changes_file>  → runtime|text|test|unknown
#   read_evidence_kind <project_root>        → none|fixture|live|both
#   write_evidence_kind <project_root> <kind> → (writes .test-status field 4)
#   check_live_evidence_artifacts <trace_dir> → present|absent
#
# @decision DEC-LIVE-E2E-002
# @title live-evidence.{txt,log,png} in $TRACE_DIR/artifacts/ is the live signal
# @status accepted
# @rationale Reuses the existing trace artifact convention (test-output.txt,
#   diff.patch, files-changed.txt, proof-evidence.txt per implementer.md
#   lines 175-179 and check-implementer.sh Check 4). Three sentinel file names
#   cover three feature classes: hooks (textual stdout → .txt), scripts with
#   long-form logs (→ .log), and UI-touching skills (screenshots → .png).
#   Non-empty file at any of those three paths = live evidence present.
#   check_live_evidence_artifacts() encapsulates this three-path check so
#   callers never hard-code the sentinel names.
#
# @decision DEC-LIVE-E2E-005
# @title Extend .test-status with evidence_kind 4th field
# @status accepted
# @rationale .test-status is already the cross-hook source of truth (read by
#   check-implementer.sh, check-guardian.sh, test-gate.sh, session-summary.sh).
#   Extending with one optional field is strictly additive: cut -d'|' -f1..3
#   on a 4-field line returns the same values as before; cut -d'|' -f4 on a
#   legacy 3-field line returns empty string, which we map to 'none'. No
#   existing reader breaks. New readers call read_evidence_kind().
#   Format: result|fail_count|timestamp|evidence_kind
#   evidence_kind ∈ {none, fixture, live, both}

set -euo pipefail

# ---------------------------------------------------------------------------
# Path classification table (DEC-LIVE-E2E-004)
# ---------------------------------------------------------------------------
# Maps file path patterns to feature classes:
#   runtime — hooks, agent prose, skills, commands, scripts, settings.json
#   text    — CLAUDE.md, README, docs, plans, research notes
#   test    — tests directory (always advisory)
#   unknown — anything else (defaults to runtime by caller convention)
#
# Most-restrictive-wins: runtime > test > text > unknown.
# Mixed-class file lists are classified as runtime.

# classify_change <file_path> → echoes "runtime|text|test|unknown"
# Pure function — no side effects, no file writes.
classify_change() {
    local file="$1"

    # Normalize: strip trailing slash, leading whitespace
    file="${file#"${file%%[! ]*}"}"   # ltrim spaces
    file="${file%/}"

    # test class: anything under a tests/ directory
    if [[ "$file" =~ /tests/|/tests$ ]]; then
        echo "test"
        return 0
    fi

    # Extract the ~/.claude/ relative portion for pattern matching.
    # Works whether the path is absolute (/home/j/.claude/hooks/foo.sh)
    # or already relative (hooks/foo.sh).
    local rel="$file"
    # Strip leading path up to and including ".claude/"
    if [[ "$file" == *"/.claude/"* ]]; then
        rel="${file#*/.claude/}"
    elif [[ "$file" == *".claude/"* ]]; then
        rel="${file#*.claude/}"
    fi

    # --- runtime patterns ---
    # hooks/*.sh  (but not lib-*.sh in a "text" subdir — all hooks are runtime)
    [[ "$rel" =~ ^hooks/[^/]+\.sh$ ]] && { echo "runtime"; return 0; }
    # agents/*.md — agent prose drives dispatch behavior
    [[ "$rel" =~ ^agents/[^/]+\.md$ ]] && { echo "runtime"; return 0; }
    # skills/**/SKILL.md or skills/**/*.sh
    [[ "$rel" =~ ^skills/.*\.(md|sh)$ ]] && { echo "runtime"; return 0; }
    # commands/*.md
    [[ "$rel" =~ ^commands/[^/]+\.md$ ]] && { echo "runtime"; return 0; }
    # scripts/*.sh
    [[ "$rel" =~ ^scripts/[^/]+\.sh$ ]] && { echo "runtime"; return 0; }
    # settings.json — changes hook wiring
    [[ "$rel" == "settings.json" || "$rel" == "settings.local.json" ]] && { echo "runtime"; return 0; }

    # --- text patterns ---
    [[ "$rel" == "CLAUDE.md" ]] && { echo "text"; return 0; }
    [[ "$rel" =~ ^README(\.md)?$ ]] && { echo "text"; return 0; }
    [[ "$rel" =~ ^docs/ ]] && { echo "text"; return 0; }
    [[ "$rel" =~ ^plans/ ]] && { echo "text"; return 0; }
    [[ "$rel" =~ ^research-log\.md$ ]] && { echo "text"; return 0; }
    [[ "$rel" =~ ^\.claude/research/ ]] && { echo "text"; return 0; }

    # --- test patterns (relative path fallback) ---
    [[ "$rel" =~ ^tests/ ]] && { echo "test"; return 0; }

    # Unknown — caller should treat as runtime (most-restrictive default)
    echo "unknown"
    return 0
}

# classify_session_changes <changes_file> → echoes most-restrictive class
# changes_file is a newline-delimited list of absolute file paths (the
# .session-changes-<SESSION_ID> file written by session hooks).
# Returns "runtime" if any path classifies as runtime or unknown.
# Returns "test" if all paths are test (or text+test mix with no runtime).
# Returns "text" only if every non-blank path classifies as text.
classify_session_changes() {
    local changes_file="${1:-}"
    [[ -z "$changes_file" || ! -f "$changes_file" ]] && { echo "unknown"; return 0; }

    local has_runtime=0
    local has_test=0
    local has_text=0
    local has_unknown=0
    local any_file=0

    while IFS= read -r path; do
        # Skip blank lines
        [[ -z "${path// /}" ]] && continue
        any_file=1
        local class
        class=$(classify_change "$path")
        case "$class" in
            runtime) has_runtime=1 ;;
            test)    has_test=1    ;;
            text)    has_text=1    ;;
            *)       has_unknown=1 ;;
        esac
    done < "$changes_file"

    # No files → unknown
    [[ "$any_file" -eq 0 ]] && { echo "unknown"; return 0; }

    # Most-restrictive wins: runtime > unknown > test > text
    [[ "$has_runtime" -eq 1 ]] && { echo "runtime"; return 0; }
    [[ "$has_unknown" -eq 1 ]] && { echo "runtime"; return 0; }  # unknown → treat as runtime
    [[ "$has_test"    -eq 1 ]] && { echo "test";    return 0; }
    echo "text"
    return 0
}

# ---------------------------------------------------------------------------
# .test-status field 4 helpers (DEC-LIVE-E2E-005)
# ---------------------------------------------------------------------------

# read_evidence_kind <project_root> → echoes "none|fixture|live|both"
# Returns "none" if the file doesn't exist or has fewer than 4 fields.
read_evidence_kind() {
    local root="${1:-.}"
    local status_file="$root/.claude/.test-status"
    [[ ! -f "$status_file" ]] && { echo "none"; return 0; }
    local field4
    field4=$(cut -d'|' -f4 < "$status_file" 2>/dev/null || echo "")
    # Validate it's a known value; default to "none" for empty or unrecognized
    case "$field4" in
        fixture|live|both) echo "$field4" ;;
        *)                 echo "none" ;;
    esac
    return 0
}

# write_evidence_kind <project_root> <kind>
# Atomically upgrades field 4 of .test-status while preserving fields 1-3.
# Upgrade logic:
#   none    + fixture → fixture
#   none    + live    → live
#   fixture + live    → both
#   live    + fixture → both
#   any     + both    → both  (both is the ceiling)
# Creates the file with "pass|0|<now>|<kind>" if it doesn't exist yet.
write_evidence_kind() {
    local root="${1:-.}"
    local new_kind="${2:?write_evidence_kind requires a kind argument}"
    local status_file="$root/.claude/.test-status"

    # Validate input
    case "$new_kind" in
        none|fixture|live|both) ;;
        *) echo "write_evidence_kind: invalid kind '$new_kind' (must be none|fixture|live|both)" >&2; return 1 ;;
    esac

    mkdir -p "$root/.claude"

    if [[ ! -f "$status_file" ]]; then
        # No existing file — create with sensible defaults
        echo "pass|0|$(date +%s)|${new_kind}" > "${status_file}.tmp.$$"
        mv "${status_file}.tmp.$$" "$status_file"
        return 0
    fi

    # Read current fields 1-3 and current evidence_kind
    local current_line
    current_line=$(head -1 "$status_file" 2>/dev/null || echo "pass|0|0")
    local f1 f2 f3 f4
    f1=$(echo "$current_line" | cut -d'|' -f1)
    f2=$(echo "$current_line" | cut -d'|' -f2)
    f3=$(echo "$current_line" | cut -d'|' -f3)
    f4=$(echo "$current_line" | cut -d'|' -f4 || echo "")

    # Normalize current f4
    case "$f4" in
        fixture|live|both) ;;
        *) f4="none" ;;
    esac

    # Compute upgrade
    local merged
    if [[ "$new_kind" == "both" || "$f4" == "both" ]]; then
        merged="both"
    elif [[ "$new_kind" == "live"    && "$f4" == "fixture" ]] || \
         [[ "$new_kind" == "fixture" && "$f4" == "live"    ]]; then
        merged="both"
    elif [[ "$new_kind" == "none" ]]; then
        merged="$f4"  # none is a no-op — don't downgrade
    else
        # Both are the same, or one is none
        [[ "$f4" != "none" ]] && merged="$f4" || merged="$new_kind"
    fi

    # Atomic write
    echo "${f1}|${f2}|${f3}|${merged}" > "${status_file}.tmp.$$"
    mv "${status_file}.tmp.$$" "$status_file"
    return 0
}

# check_live_evidence_artifacts <trace_dir> → echoes "present|absent"
# A non-empty file at any of the three sentinel paths counts as present.
check_live_evidence_artifacts() {
    local trace_dir="${1:-}"
    [[ -z "$trace_dir" ]] && { echo "absent"; return 0; }
    for ext in txt log png; do
        local artifact="${trace_dir}/artifacts/live-evidence.${ext}"
        if [[ -f "$artifact" && -s "$artifact" ]]; then
            echo "present"
            return 0
        fi
    done
    echo "absent"
    return 0
}
