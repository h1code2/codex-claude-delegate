---
name: build-loop
description: Start a delegate loop — Codex plans and reviews, Claude Code implements all code
---

You are the **supervisor**, not the implementer. Claude Code writes all source code.

## Setup

```bash
bash "${PLUGIN_ROOT}/scripts/setup-build-loop.sh" "$ARGUMENTS"
```

## Phase 1 — Plan

1. Analyze the task and codebase (read-only exploration)
2. Write `.codex/delegate-spec.md` with scope, files, acceptance criteria, test plan
3. **Do not edit source code** — only `.codex/` and `reviews/`
4. **Immediately after the spec is written**, prepare delegation:

```bash
bash "${PLUGIN_ROOT}/scripts/prepare-delegate.sh"
```

This creates `.codex/claude-prompt.txt` and `.codex/delegate-run-claude.sh`.

> **Why?** The runner is NOT created by `setup-build-loop.sh`. Stop hook also generates it, but only when you end a turn. Codex desktop often continues in the same turn, so always run `prepare-delegate.sh` explicitly.

## Phase 2 — Delegate

```bash
bash .codex/delegate-run-claude.sh
```

If the runner is missing:

```bash
bash "${PLUGIN_ROOT}/scripts/prepare-delegate.sh"
bash .codex/delegate-run-claude.sh
```

The runner has its own timeout (`DELEGATE_TIMEOUT_SECONDS`, default 1800). If Claude times out or is interrupted after writing source changes, stop your turn so the hook can move to review.

## Phase 3 — Review

1. Run `git diff`, `git diff --cached`, relevant tests
2. Write `reviews/review-<task_id>.md` (read task_id from `.codex/delegate-loop.local.md`)
3. End with exactly: `## Result: PASS` or `## Result: FAIL`
4. Do not fix source code yourself

## Phase 4 — Fix (if FAIL)

Stop hook prepares the fix prompt on turn end. Or run explicitly:

```bash
bash "${PLUGIN_ROOT}/scripts/prepare-delegate.sh --fix"
bash .codex/delegate-run-claude.sh
```

## Rules

- Never implement features directly — delegate to Claude Code
- Always run `prepare-delegate.sh` after writing the spec (do not skip)
- Trust plugin hooks via `/hooks` on first use
