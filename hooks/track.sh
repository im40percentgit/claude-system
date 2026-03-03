#!/usr/bin/env bash
# Project-aware file change tracking.
# PostToolUse hook — matcher: Write|Edit
#
# Tracks file changes per-session in the PROJECT's .claude directory.
# Uses CLAUDE_PROJECT_DIR when available, falls back to git root detection.
# Session-scoped to avoid collisions with concurrent sessions.
#
# @decision DEC-PROOF-PATH-001
# @title Use resolve_proof_file() for proof-status invalidation path
# @status accepted
# @rationale Hardcoded PROOF_FILE="$TRACKING_DIR/.proof-status" missed worktree-specific
#   proof files. resolve_proof_file() reads the breadcrumb written by task-track.sh
#   Gate C to find the active proof-status path (global or worktree-local). Fixes #10.

set -euo pipefail

source "$(dirname "$0")/source-lib.sh"

HOOK_INPUT=$(read_input)
FILE_PATH=$(get_field '.tool_input.file_path')

# Exit silently if no file path
[[ -z "$FILE_PATH" ]] && exit 0

# Exit silently if parent directory doesn't exist
[[ ! -e "$(dirname "$FILE_PATH")" ]] && exit 0

# Detect project root (prefers CLAUDE_PROJECT_DIR)
PROJECT_ROOT=$(detect_project_root)

# Session-scoped tracking file (tracks file changes, not decisions)
SESSION_ID="${CLAUDE_SESSION_ID:-$$}"
TRACKING_DIR="$PROJECT_ROOT/.claude"
TRACKING_FILE="$TRACKING_DIR/.session-changes-${SESSION_ID}"

# Create tracking directory if needed
mkdir -p "$TRACKING_DIR"

# Atomic append: write to temp then append (safer than direct >>)
TMPFILE=$(mktemp "${TRACKING_DIR}/.track.XXXXXX")
echo "$FILE_PATH" > "$TMPFILE"
cat "$TMPFILE" >> "$TRACKING_FILE"
rm -f "$TMPFILE"

# --- Invalidate proof-status when non-test source files change ---
# If user verified the feature and then source code changes, proof is stale.
PROOF_FILE=$(resolve_proof_file)
if [[ -f "$PROOF_FILE" ]]; then
    PROOF_STATUS=$(cut -d'|' -f1 "$PROOF_FILE")
    if [[ "$PROOF_STATUS" == "verified" ]]; then
        # Only invalidate for source file changes (not tests, config, docs)
        if [[ "$FILE_PATH" =~ \.(ts|tsx|js|jsx|py|rs|go|java|kt|swift|c|cpp|h|hpp|cs|rb|php|sh|bash|zsh)$ ]] \
           && [[ ! "$FILE_PATH" =~ (\.test\.|\.spec\.|__tests__|\.config\.|node_modules|vendor|dist|\.git|\.claude) ]]; then
            echo "pending|$(date +%s)" > "$PROOF_FILE"
        fi
    fi
fi

exit 0
