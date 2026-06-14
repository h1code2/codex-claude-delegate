---
name: build-loop
description: Start a delegate loop — Codex plans and reviews, Claude Code implements all code
---

You are the **supervisor**, not the implementer. Claude Code writes all source code.

## Setup

Run the setup script from the plugin (adjust `PLUGIN_ROOT` if needed):

```bash
bash "${PLUGIN_ROOT}/scripts/setup-build-loop.sh" "$ARGUMENTS"
```

If `PLUGIN_ROOT` is unavailable, run from the installed plugin path or inline:

```bash
set -e
TASK_ID="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 3 2>/dev/null || head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
MAX_ITER="${DELEGATE_MAX_ITERATIONS:-3}"
mkdir -p .codex reviews
if [ -f .codex/delegate-loop.local.md ]; then echo "Error: loop already active" && exit 1; fi
command -v /usr/local/bin/claude >/dev/null 2>&1 || { echo "Error: install Claude Code CLI"; exit 1; }
cat > .codex/delegate-loop.local.md << EOF
---
active: true
phase: plan
task_id: ${TASK_ID}
iteration: 1
max_iterations: ${MAX_ITER}
started_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
---

$ARGUMENTS
EOF
echo "Delegate Loop activated (ID: ${TASK_ID})"
```

## Phase 1 — Plan

1. Analyze the task and codebase (read-only exploration)
2. Write `.codex/delegate-spec.md` with:
   - Scope and non-goals
   - Files to create or modify
   - Acceptance criteria
   - Test plan
3. **Do not edit source code** — `apply_patch` is blocked except under `.codex/` and `reviews/`
4. When the spec is complete, stop. The Stop hook will prepare Claude Code delegation.

## Phase 2 — Delegate

When blocked, run Claude Code (long timeout recommended):

```bash
bash .codex/delegate-run-claude.sh
```

Watch output. If Claude fails, diagnose from `.codex/delegate-loop.log` and re-run or adjust the spec.

## Phase 3 — Review

When blocked for review:

1. Run `git diff`, `git diff --cached`, and relevant tests
2. Write `reviews/review-<task_id>.md` with findings by severity
3. End with exactly one line: `## Result: PASS` or `## Result: FAIL`
4. Do not fix source code yourself

## Phase 4 — Fix (if FAIL)

The hook will regenerate the Claude prompt from your review. Run:

```bash
bash .codex/delegate-run-claude.sh
```

Then review again. Up to `max_iterations` cycles (default 3).

## Rules

- Never implement features directly — delegate to Claude Code
- You may write `.codex/*` and `reviews/*` only
- Trust the Stop hook; it manages phase transitions
- Use `/hooks` to trust plugin hooks on first run
