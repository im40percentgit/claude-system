#!/usr/bin/env bash
# record-live-evidence.sh — CLI wrapper around write_evidence_kind.
# Call this after capturing a live evidence artifact to upgrade .test-status
# field 4 so gates can see the evidence_kind signal.
#
# @decision DEC-LIVE-E2E-005
# @title CLI wrapper for .test-status evidence_kind field upgrade
# @status accepted
# @rationale Agents (implementer, tester) need a stable CLI entry point to
#   record live evidence without sourcing lib-live-e2e.sh directly. A wrapper
#   script decouples the callers from the library internals and makes the
#   invocation visible in agent instructions as a single command. The script
#   auto-detects project root from CLAUDE_PROJECT_ROOT env or by walking the
#   CWD to find .git/.claude, so agents don't need to pass --project
#   explicitly in the common case.
#
# Usage:
#   ~/.claude/scripts/record-live-evidence.sh --kind live
#   ~/.claude/scripts/record-live-evidence.sh --kind fixture
#   ~/.claude/scripts/record-live-evidence.sh --kind both
#   ~/.claude/scripts/record-live-evidence.sh --kind live --project /path/to/project
#
# The implementer calls this after writing $TRACE_DIR/artifacts/live-evidence.txt
# (or .log or .png). The tester calls it after capturing the live demo transcript.
#
# Exit codes:
#   0 — success
#   1 — invalid arguments or write failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$(dirname "$SCRIPT_DIR")/hooks"

source "${HOOKS_DIR}/lib-live-e2e.sh"

# --- Parse arguments ---
KIND=""
PROJECT_ROOT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kind)
            KIND="${2:?--kind requires a value (none|fixture|live|both)}"
            shift 2
            ;;
        --project)
            PROJECT_ROOT="${2:?--project requires a path}"
            shift 2
            ;;
        --help|-h)
            echo "Usage: record-live-evidence.sh --kind <none|fixture|live|both> [--project <path>]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: record-live-evidence.sh --kind <none|fixture|live|both> [--project <path>]" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$KIND" ]]; then
    echo "Error: --kind is required" >&2
    echo "Usage: record-live-evidence.sh --kind <none|fixture|live|both> [--project <path>]" >&2
    exit 1
fi

# Auto-detect project root if not provided
if [[ -z "$PROJECT_ROOT" ]]; then
    # Try CLAUDE_PROJECT_ROOT env var (set by hooks)
    if [[ -n "${CLAUDE_PROJECT_ROOT:-}" ]]; then
        PROJECT_ROOT="$CLAUDE_PROJECT_ROOT"
    else
        # Walk up from CWD to find a .git or .claude directory
        dir="$PWD"
        while [[ "$dir" != "/" ]]; do
            if [[ -d "$dir/.git" || -d "$dir/.claude" ]]; then
                PROJECT_ROOT="$dir"
                break
            fi
            dir="$(dirname "$dir")"
        done
    fi
fi

if [[ -z "$PROJECT_ROOT" ]]; then
    echo "Error: could not auto-detect project root. Use --project to specify it." >&2
    exit 1
fi

write_evidence_kind "$PROJECT_ROOT" "$KIND"

# Confirm to the caller
CURRENT=$(read_evidence_kind "$PROJECT_ROOT")
echo "record-live-evidence: evidence_kind upgraded to '$CURRENT' in $PROJECT_ROOT/.claude/.test-status"
