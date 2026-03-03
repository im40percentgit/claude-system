#!/usr/bin/env bash
# PreToolUse:Task — track subagent spawns for status bar.
#
# Fires before every Task tool dispatch. Extracts subagent_type
# from tool_input and updates .subagent-tracker + .statusline-cache.
#
# @decision DEC-CACHE-003
# @title Use PreToolUse:Task as SubagentStart replacement
# @status accepted
# @rationale SubagentStart hooks don't fire in Claude Code v2.1.38.
#   PreToolUse:Task demonstrably fires before every Task dispatch.
#
# @decision DEC-PROOF-PATH-001
# @title Use resolve_proof_file() for all proof-status path resolution
# @status accepted
# @rationale Hardcoded CLAUDE_DIR/.proof-status caused clobbering when multiple
#   implementers/testers ran in parallel worktrees. resolve_proof_file() reads
#   a per-project breadcrumb (.active-worktree-path-{phash}) to find the
#   worktree-specific proof file. Gate C writes this breadcrumb when an
#   implementer is dispatched from inside a worktree (PROJECT_ROOT != main
#   worktree path). Fixes issue #10.

set -euo pipefail

source "$(dirname "$0")/log.sh"
source "$(dirname "$0")/context-lib.sh"

HOOK_INPUT=$(read_input)
AGENT_TYPE=$(echo "$HOOK_INPUT" | jq -r '.tool_input.subagent_type // "unknown"' 2>/dev/null)

PROJECT_ROOT=$(detect_project_root)
CLAUDE_DIR=$(get_claude_dir)

# Track spawn and refresh statusline cache
track_subagent_start "$PROJECT_ROOT" "$AGENT_TYPE"
get_git_state "$PROJECT_ROOT"
get_plan_status "$PROJECT_ROOT"
write_statusline_cache "$PROJECT_ROOT"

# Emit PreToolUse deny response with reason, then exit.
deny() {
    local reason="$1"
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "$reason"
  }
}
EOF
    exit 0
}

# --- Gate A: Guardian requires .proof-status = verified (when active) ---
# Gate is only active when .proof-status file exists (created by implementer dispatch).
# Missing file = no implementation in progress = allow (fixes bootstrap deadlock).
# Meta-repo (~/.claude) is exempt — no feature verification needed for config.
if [[ "$AGENT_TYPE" == "guardian" ]]; then
    if ! is_claude_meta_repo "$PROJECT_ROOT"; then
        PROOF_FILE=$(resolve_proof_file)
        if [[ -f "$PROOF_FILE" ]]; then
            PROOF_STATUS=$(cut -d'|' -f1 "$PROOF_FILE")
            if [[ "$PROOF_STATUS" != "verified" ]]; then
                deny "Cannot dispatch Guardian: proof-of-work is '$PROOF_STATUS' (requires 'verified'). Dispatch tester or complete verification before dispatching Guardian."
            fi
        fi
        # File missing → no implementation in progress → allow (bootstrap path)
    fi
fi

# --- Gate B: Tester requires implementer trace (advisory) ---
# Prevents premature tester dispatch before implementer has returned.
# Meta-repo (~/.claude) is exempt.
if [[ "$AGENT_TYPE" == "tester" ]]; then
    if ! is_claude_meta_repo "$PROJECT_ROOT"; then
        IMPL_TRACE=$(detect_active_trace "$PROJECT_ROOT" "implementer" 2>/dev/null || echo "")
        if [[ -n "$IMPL_TRACE" ]]; then
            # Active trace means implementer hasn't returned yet
            IMPL_MANIFEST="${TRACE_STORE}/${IMPL_TRACE}/manifest.json"
            IMPL_STATUS=$(jq -r '.status // "unknown"' "$IMPL_MANIFEST" 2>/dev/null || echo "unknown")
            if [[ "$IMPL_STATUS" == "active" ]]; then
                deny "Cannot dispatch tester: implementer trace '$IMPL_TRACE' is still active. Wait for the implementer to return before verifying."
            fi
        fi
    fi
fi

# --- Gate C: Implementer dispatch activates proof gate ---
# Creates .proof-status = needs-verification when implementer is dispatched.
# This activates Gate A — Guardian will be blocked until verification completes.
# Meta-repo (~/.claude) is exempt.
# Also writes a worktree breadcrumb when running inside a worktree, so that
# resolve_proof_file() can locate the worktree-specific proof file.
if [[ "$AGENT_TYPE" == "implementer" ]]; then
    if ! is_claude_meta_repo "$PROJECT_ROOT"; then
        # Write breadcrumb if dispatching from inside a worktree
        MAIN_WORKTREE=$(git -C "$PROJECT_ROOT" worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
        if [[ -n "$MAIN_WORKTREE" && "$PROJECT_ROOT" != "$MAIN_WORKTREE" ]]; then
            BREADCRUMB_PHASH=$(project_hash "$PROJECT_ROOT")
            echo "$PROJECT_ROOT" > "${CLAUDE_DIR}/.active-worktree-path-${BREADCRUMB_PHASH}"
        fi

        PROOF_FILE=$(resolve_proof_file)
        # Only activate if no proof flow is already active
        if [[ ! -f "$PROOF_FILE" ]]; then
            mkdir -p "$(dirname "$PROOF_FILE")"
            echo "needs-verification|$(date +%s)" > "$PROOF_FILE"
        fi
    fi
fi

exit 0
