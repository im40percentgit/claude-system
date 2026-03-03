---
name: backlog
description: Manage your backlog — list, create, close, triage, and enrich todos (GitHub Issues). Usage: /backlog [text | done <#> | stale | review | group | enrich <#> | --global | --config | --project]
argument-hint: "[todo text | done <#> | stale | review | group <component> #N... | enrich <#> [--force] | --global | --config | --project]"
---

# /backlog — Unified Backlog Management

Create, list, close, and triage todos (GitHub Issues labeled `claude-todo`).

## JSON output pattern

**IMPORTANT:** For read-only list commands, redirect `--json` output to a scratchpad file so the user never sees raw JSON in the Bash tool output. Then use the Read tool to silently parse the file and format a clean table.

Pattern:
1. `mkdir -p "$SCRATCHPAD" && ~/.claude/scripts/todo.sh list <flags> --json > "$SCRATCHPAD/backlog.json"` (Bash — produces no visible output)
2. Read `$SCRATCHPAD/backlog.json` (Read tool — silent ingestion)
3. Format the parsed data into the display table below

Write commands (add, done) stay as-is — their confirmation output is useful raw. The `stale` command doesn't support `--json` — its raw output is short and already well-formatted, so run it directly.

## Instructions

Parse `$ARGUMENTS` to determine the action:

### No arguments → List all todos
```bash
mkdir -p "$SCRATCHPAD" && ~/.claude/scripts/todo.sh list --all --json > "$SCRATCHPAD/backlog.json"
```
Read `$SCRATCHPAD/backlog.json`, then format into the markdown table described in Display Format below.

### First word is `done` → Close a todo
```bash
~/.claude/scripts/todo.sh done <number>
```
Extract the issue number from the remaining arguments. If the user specifies `--global`, add that flag. If the issue number belongs to the global repo, add `--global`.

### First word is `stale` → Show old todos that need attention
```bash
~/.claude/scripts/todo.sh stale
```
Show stale items and ask the user which to close, keep, or reprioritize.

### First word is `review` → Interactive triage
1. Run `mkdir -p "$SCRATCHPAD" && ~/.claude/scripts/todo.sh list --all --json > "$SCRATCHPAD/backlog.json"`, then Read the file.
2. Parse the JSON.
3. **Cross-reference scan:** Before presenting items, identify semantically related issues across both scopes (project and global). Flag pairs/clusters that should be linked or merged.
4. Present each todo one by one, noting any related issues found
5. For each, ask: **Keep**, **Close**, **Reprioritize**, or **Link** (to a related issue)?
6. Execute the user's decision — for Link actions, add cross-reference comments on both issues

### Argument is `--project`, `--global`, or `--config` alone → Scoped listing
```bash
mkdir -p "$SCRATCHPAD" && ~/.claude/scripts/todo.sh list --project --json > "$SCRATCHPAD/backlog.json"
mkdir -p "$SCRATCHPAD" && ~/.claude/scripts/todo.sh list --global --json > "$SCRATCHPAD/backlog.json"
mkdir -p "$SCRATCHPAD" && ~/.claude/scripts/todo.sh list --config --json > "$SCRATCHPAD/backlog.json"
```
Read `$SCRATCHPAD/backlog.json`, then format into the markdown table described in Display Format below.

### First word is `group` → Add component label to issues
```bash
~/.claude/scripts/todo.sh group <component> <issue-numbers...> [--global|--config]
```
Labels the specified issues with `component:<name>`. Example: `group auth 31 28` labels both issues with `component:auth`.

### First word is `ungroup` → Remove component label from issues
```bash
~/.claude/scripts/todo.sh ungroup <component> <issue-numbers...> [--global|--config]
```

### Argument is `--grouped` → Grouped listing by component
```bash
mkdir -p "$SCRATCHPAD" && ~/.claude/scripts/todo.sh list --all --grouped > "$SCRATCHPAD/backlog-grouped.txt"
```
Read the file and present to the user. Issues are grouped by `component:*` label with an "ungrouped" bucket for untagged issues. Useful for `review --grouped` to triage one component at a time.

### First word is `attach` → Attach image to an issue
```bash
~/.claude/scripts/todo.sh attach <issue-number> <image-path> [--global|--config] [--gist]
```
Saves the image locally to `~/.claude/todo-images/` and optionally uploads to a GitHub Gist. Adds a comment on the issue with the image reference.

### First word is `images` → List images for an issue
```bash
~/.claude/scripts/todo.sh images <issue-number> [--global|--config]
```

### First word is `enrich` → Enrich an issue with AI-generated content

<!-- @decision DEC-ENRICH-001
     Orchestration lives here (backlog.md slash command) rather than a standalone
     bash script because generating acceptance criteria and PRD skeletons requires
     Claude's intelligence. Bash handles only classification and label checks.
     Addresses: REQ-P0-002. -->

<!-- @decision DEC-ENRICH-002
     Keyword-based heuristics classify complexity: simple/medium/complex.
     Implemented in scripts/enrich-classify.sh. No ML, no external deps.
     Addresses: REQ-P0-001. -->

Extract the issue number from the remaining arguments (strip leading `#` if present).
Also check for `--force` flag in the arguments.

**Step 1 — Read the issue:**
```bash
gh issue view <N> --repo juanandresgs/claude-ctrl --json title,body,labels
```
Save the output to `$SCRATCHPAD/enrich-issue.json`. Read it silently with the Read tool.

**Step 2 — Check for `enriched` label:**
From the JSON, inspect the `labels` array. If any label has `name == "enriched"` AND `--force` was NOT passed:
- Report: "Issue #N already has the `enriched` label. Use `--force` to re-enrich."
- Stop here.

**Step 3 — Classify complexity:**
```bash
source ~/.claude/scripts/enrich-classify.sh
classify_complexity "<title>" "<body>"
```
Or call directly:
```bash
~/.claude/scripts/enrich-classify.sh "<title>" "<body>"
```
Capture the output as `TIER` (one of: `simple`, `medium`, `complex`).

**Step 4 — Dispatch by tier:**

#### Tier: simple
Report to the user:
```
Issue #N classified as: simple
Title: <title>
This issue is classified as simple — no enrichment needed.
Tip: If this turns out to be more involved than expected, re-run with /backlog enrich <N> --force
```
Stop here. No further action required.

#### Tier: medium

<!-- @decision DEC-ENRICH-004
     In-place body update wraps original content in a <details> block and prepends
     enriched sections above it. No original text is lost. Uses `gh issue edit --body`
     with a variable (not a file) to keep the flow self-contained in the slash command.
     Addresses: REQ-P0-005. -->

Report to the user: "Issue #N classified as medium — running enrichment now."

**Medium enrichment steps:**

**Step M1 — Extract title and original body from already-fetched JSON:**
You already have the issue JSON in `$SCRATCHPAD/enrich-issue.json`. Parse out `title` and `body` from that file. Call the title `ISSUE_TITLE` and the body `ORIGINAL_BODY`.

**Step M2 — Identify affected files:**
Analyze the keywords in `ISSUE_TITLE` and `ORIGINAL_BODY`. Extract 3-6 meaningful technical terms (function names, module names, feature areas, path fragments). Then use Grep and Glob to search the codebase for files most related to those keywords. For example:
- Use Glob with patterns like `**/<keyword>*`, `**/*<keyword>*` to find files by name
- Use Grep to search file contents for the keywords

Collect the top 5-10 most relevant file paths. These will become the `AFFECTED_FILES` list.

**Step M3 — Generate acceptance criteria:**
Analyze `ISSUE_TITLE` and `ORIGINAL_BODY`. Generate 3-5 concrete, testable acceptance criteria as checkbox items. Each criterion should describe a verifiable outcome. Format them as:
```
- [ ] <criterion>
```
Call this list `ACCEPTANCE_CRITERIA`.

**Step M4 — Build the enriched body:**
Construct the new issue body by combining the enriched sections with the original content preserved in a collapsible details block. The structure must be exactly:

```
## Enriched by /backlog enrich

### Complexity: Medium

### Acceptance Criteria

<ACCEPTANCE_CRITERIA items, one per line>

### Affected Files

<AFFECTED_FILES paths, one per line as a bullet list>

---
<details><summary>Original Issue</summary>

<ORIGINAL_BODY>

</details>
```

**Step M5 — Update the issue body:**
Write the enriched body to a temporary file to handle multi-line content and special characters safely:

```bash
ENRICHED_BODY_FILE="$SCRATCHPAD/enriched-body-N.md"
cat > "$ENRICHED_BODY_FILE" << 'ENRICH_EOF'
<the full enriched body constructed in Step M4>
ENRICH_EOF

gh issue edit <N> --repo juanandresgs/claude-ctrl --body "$(cat "$ENRICHED_BODY_FILE")"
```

Write the actual content (not a placeholder) to the file before calling `gh issue edit`.

**Step M6 — Add the `enriched` label:**
```bash
source ~/.claude/scripts/todo.sh
ensure_enriched_label "juanandresgs/claude-ctrl"
gh issue edit <N> --repo juanandresgs/claude-ctrl --add-label "enriched"
```

Report to the user:
```
Issue #N enriched successfully.
Title: <title>
Tier: medium
Acceptance criteria: <N> items generated
Affected files: <N> files identified
Label `enriched` added.
View: https://github.com/juanandresgs/claude-ctrl/issues/<N>
```

#### Tier: complex

<!-- @decision DEC-ENRICH-003
     Rate limiting via TSV log file (~/.config/cc-todos/enrich-log.tsv). Max 3
     complex enrichments per rolling hour, checked before invoking deep-research.
     TSV is human-readable, zero-dependency, and auditable. Addresses: REQ-P0-007. -->

**Complex enrichment steps:**

**Step C1 — Rate limit check:**
```bash
source ~/.claude/scripts/enrich-ratelimit.sh
check_rate_limit
```
If `check_rate_limit` returns 1 (over limit), use AskUserQuestion before proceeding:
- Header: "Rate limit reached"
- Question: "You have already run 3 complex enrichments in the last hour (the maximum). Running another will invoke /deep-research and consume additional API credits. Proceed anyway?"
- Options: ["Yes, proceed anyway", "No, skip for now"]

If the user chooses "No, skip for now", stop here and report:
```
Complex enrichment skipped — rate limit reached (3/3 this hour).
Try again after the hour window resets, or use --force to bypass.
```

**Step C2 — Confirmation prompt:**
Even if under rate limit, use AskUserQuestion to confirm cost before proceeding:
- Header: "Complex enrichment"
- Question: "Issue #N is classified as complex. Enrichment will invoke /deep-research (takes 2-10 minutes and uses API credits). Proceed?"
- Options: ["Yes, run deep-research and generate PRD skeleton", "No, skip enrichment"]

If the user declines, stop here and report:
```
Complex enrichment skipped for issue #N.
Tip: Run /backlog enrich <N> again when ready.
```

**Step C3 — Extract title and original body:**
You already have the issue JSON in `$SCRATCHPAD/enrich-issue.json`. Parse out `title` and `body` from that file. Call the title `ISSUE_TITLE` and the body `ORIGINAL_BODY`.

**Step C4 — Run deep-research:**
Invoke the deep-research skill with the issue title as the research query:
```
Use the Skill tool: skill="deep-research", args="<ISSUE_TITLE>"
```
The skill produces a comparative research report. Capture the key findings — the most relevant options, trade-offs, prior art, and recommendations — as `RESEARCH_FINDINGS`. Distill to 4-8 bullet points suitable for an issue body section.

**Step C5 — Generate PRD skeleton:**
Based on `ISSUE_TITLE`, `ORIGINAL_BODY`, and `RESEARCH_FINDINGS`, generate a PRD skeleton inline. Do NOT invoke the /prd skill — generate it directly following this template:

```
#### Problem Statement
<1-2 sentences: what pain exists and for whom>

#### Goals
- <goal 1>
- <goal 2>
- <goal 3>

#### Non-Goals
- <non-goal 1>
- <non-goal 2>

#### Requirements

**P0 (Must Have)**
- <P0 requirement 1>
- <P0 requirement 2>

**P1 (Nice to Have)**
- <P1 requirement 1>

#### Key Decisions
- <decision or open question 1>
- <decision or open question 2>
```

Call this `PRD_SKELETON`.

**Step C6 — Generate acceptance criteria:**
From `PRD_SKELETON`'s P0 requirements, generate 4-6 concrete, testable acceptance criteria as checkbox items. Format:
```
- [ ] <criterion>
```
Call this `ACCEPTANCE_CRITERIA`.

**Step C7 — Identify affected files:**
Analyze keywords in `ISSUE_TITLE` and `ORIGINAL_BODY`. Extract 3-6 meaningful technical terms. Use Grep and Glob to search the codebase for the most related files. Collect the top 5-10 most relevant paths as `AFFECTED_FILES`.

**Step C8 — Build the enriched body:**
Construct the full enriched body in this exact structure:

```
## Enriched by /backlog enrich

### Complexity: Complex

### Research Summary

<RESEARCH_FINDINGS bullets, one per line>

### PRD Skeleton

<PRD_SKELETON content>

### Acceptance Criteria

<ACCEPTANCE_CRITERIA items, one per line>

### Affected Files

<AFFECTED_FILES paths, one per line as a bullet list>

---
<details><summary>Original Issue</summary>

<ORIGINAL_BODY>

</details>
```

**Step C9 — Update the issue body:**
Write the enriched body to a temp file to handle multi-line content safely:
```bash
ENRICHED_BODY_FILE="$SCRATCHPAD/enriched-body-N.md"
cat > "$ENRICHED_BODY_FILE" << 'ENRICH_EOF'
<the full enriched body constructed in Step C8>
ENRICH_EOF

gh issue edit <N> --repo juanandresgs/claude-ctrl --body "$(cat "$ENRICHED_BODY_FILE")"
```

**Step C10 — Add label and log:**
```bash
source ~/.claude/scripts/todo.sh
ensure_enriched_label "juanandresgs/claude-ctrl"
gh issue edit <N> --repo juanandresgs/claude-ctrl --add-label "enriched"

# Record this run in the rate limit log
source ~/.claude/scripts/enrich-ratelimit.sh
log_enrichment <N> complex <duration_seconds>
```
For `<duration_seconds>`, capture the wall-clock time of Steps C4-C9 (approximate seconds elapsed since Step C4 started).

Report to the user:
```
Issue #N enriched successfully.
Title: <title>
Tier: complex
Research summary: <N> findings
PRD skeleton: generated (Problem Statement, Goals, Non-Goals, Requirements, Key Decisions)
Acceptance criteria: <N> items generated
Affected files: <N> files identified
Label `enriched` added.
View: https://github.com/juanandresgs/claude-ctrl/issues/<N>
```

### Otherwise → Create a new todo
Treat the entire `$ARGUMENTS` as todo text (plus any flags like `--global`, `--config`, `--priority=high|medium|low`, `--image=path`, `--gist`):
```bash
~/.claude/scripts/todo.sh add $ARGUMENTS
```

After creating the issue:
1. **Extract the issue number** from the creation output URL (format: `https://github.com/owner/repo/issues/N`).
2. **Clean up the title:** If the raw title is longer than 70 characters or reads as a stream-of-consciousness brain dump, propose a concise professional title (under 70 chars, imperative form) and apply it via `gh issue edit <N> --title "<clean title>"`. The original raw text is preserved in the issue body's Problem section.
3. **Cross-reference check:** Scan existing issues (both project and global — use session-init context or `todo.sh list --all`) for semantically related topics. If a related issue exists in either scope, add a comment on **both** issues linking them (e.g., "**Related:** owner/repo#N — <brief reason>"). This catches duplicates and ensures agents see connections when they pick up work.
4. **Brief interview:** Ask the user 1-2 quick follow-up questions using AskUserQuestion:
   - "What does 'done' look like? Any specific acceptance criteria?" (header: "Criteria")
   - Options: 2-3 concrete suggestions based on the title + "Skip — I'll fill this in later"
   The question should be a single AskUserQuestion call with one question and relevant options inferred from the issue title.
5. **Enrich if answered:** If the user provides acceptance criteria (not "Skip"), edit the issue body to replace the `- [ ] TBD` placeholder with the user's criteria via `gh issue edit <N> --body "<updated body>"`. Read the current body first, then substitute the TBD line.
6. **Confirm** to the user with the issue URL, clean title, and any cross-references found.

## Scope Rules

- **Default (no flag)**: Saves to / lists from current project's GitHub repo issues
- **`--global`**: Uses the global backlog repo (`<your-github-user>/cc-todos`, auto-detected)
- **`--config`**: Uses the harness repo (`~/.claude` git remote, e.g. `user/claude-system`). For filing harness bugs and config improvements from any project directory.
- If not in a git repo, automatically falls back to global

## Display Format

Present todos as a markdown table, one section per scope. Use columns: `#`, `Pri`, `Title`, `Created`, and `Status` (for labels like blocked/assigned). Truncate titles at ~60 chars with `...` if needed.

Example:

**GLOBAL** [user/cc-todos] (3 open)

| # | Pri | Title | Created | Status |
|---|-----|-------|---------|--------|
| 18 | HIGH | Session-aware todo claiming | 2026-02-07 | |
| 14 | MED | Figure out Claude web + queued todos | 2026-02-07 | blocked |
| 7 | LOW | nvim: Add `<Space>h` for comment toggle | 2026-02-06 | |

**PROJECT** [owner/repo] (2 open)

| # | Pri | Title | Created | Status |
|---|-----|-------|---------|--------|
| 42 | | Fix auth middleware | 2026-01-20 | |
| 43 | | Add rate limiting | 2026-02-01 | assigned |

**CONFIG** [user/claude-system] (1 open)

| # | Pri | Title | Created | Status |
|---|-----|-------|---------|--------|
| 5 | MED | Fix session-init hook timing | 2026-02-08 | |

For stale items, flag them: "This todo is 21 days old — still relevant?"
