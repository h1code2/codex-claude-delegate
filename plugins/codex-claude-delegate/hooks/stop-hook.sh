#!/usr/bin/env bash
# Delegate Loop — Stop Hook
#
# Phases:
#   plan     → Codex writes spec, no source edits
#   delegate → Codex runs Claude Code via runner script
#   review   → Codex reviews git diff, writes review file
#   fix      → Codex sends review feedback back to Claude Code
#
# Fail-open on errors so users are never trapped.
# Runner generation is duplicated in prepare-delegate.sh for when Stop does not fire.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/delegate-lib.sh
source "${HOOK_DIR}/../scripts/delegate-lib.sh"

fail_open() {
  delegate_log "ERROR: $* — failing open"
  rm -f "$STATE_FILE" .codex/delegate-loop.lock \
    .codex/delegate-run-claude.sh .codex/claude-prompt.txt .codex/delegate-loop-retries \
    .codex/delegate-claude-done
  printf '{}\n'
  exit 0
}

trap 'fail_open "hook exited via ERR trap (line $LINENO)"' ERR

HOOK_INPUT=$(cat)

if [ ! -f "$STATE_FILE" ]; then
  printf '{}\n'
  exit 0
fi

ACTIVE=$(sed -n 's/^active: *//p' "$STATE_FILE" | head -1)
if [ "$ACTIVE" != "true" ]; then
  rm -f "$STATE_FILE"
  printf '{}\n'
  exit 0
fi

if ! load_delegate_state; then
  fail_open "invalid delegate state"
fi

block_with_reason() {
  local reason="$1"
  local system_msg="$2"
  jq -n --arg r "$reason" --arg s "$system_msg" \
    '{decision: "block", reason: $r, systemMessage: $s}' 2>/dev/null \
    || printf '{"decision":"block","reason":"%s","systemMessage":"%s"}\n' "$reason" "$system_msg"
}

case "$PHASE" in
  plan)
    if [ ! -f "$SPEC_FILE" ]; then
      block_with_reason \
        "Planning is not complete. Write the implementation spec to ${SPEC_FILE} (scope, files, acceptance criteria, test plan). Do not edit source code — Claude Code will implement." \
        "Delegate Loop [${TASK_ID}] — Phase 1/4: Planning"
      exit 0
    fi

    prepare_delegate_from_plan || fail_open "prepare_delegate_from_plan failed"

    block_with_reason \
      "Planning complete. Run Claude Code to implement (use a long Bash timeout, e.g. 600000ms):

\`\`\`
bash .codex/delegate-run-claude.sh
\`\`\`

If the runner is missing, run: bash \"\${PLUGIN_ROOT}/scripts/prepare-delegate.sh\"

After Claude finishes, stop again to enter the review phase." \
      "Delegate Loop [${TASK_ID}] — Phase 2/4: Delegate to Claude Code"
    ;;

  delegate)
    if [ -f ".codex/delegate-claude-done" ] || [ -f ".codex/delegate-claude-needs-review" ]; then
      REVIEW_REASON="Implementation phase complete."
      if [ -f ".codex/delegate-claude-needs-review" ]; then
        REVIEW_REASON="Claude delegate was interrupted or timed out after writing changes. Review the diff carefully."
      fi

      rm -f .codex/delegate-run-claude.sh .codex/delegate-claude-done \
        .codex/delegate-claude-interrupted .codex/delegate-claude-needs-review \
        .codex/delegate-loop-retries .codex/delegate-loop.local.md.runner-backup
      if [ "$ITERATION" -gt 1 ]; then
        rm -f "$REVIEW_FILE"
      fi
      transition_phase "review"

      block_with_reason \
        "${REVIEW_REASON} Perform an independent review:

1. Run \`git diff\` and \`git diff --cached\` (and \`git log --oneline -5\` if needed)
2. Check code quality, tests, security (OWASP top 10), and spec coverage
3. Write findings to ${REVIEW_FILE} with severity (critical/high/medium/low) and suggested fixes
4. End with \`## Result: PASS\` or \`## Result: FAIL\`

Do not fix source code yourself — only write the review file." \
        "Delegate Loop [${TASK_ID}] — Phase 3/4: Review"
      exit 0
    fi

    if [ -f ".codex/delegate-run-claude.sh" ]; then
      RETRY_FILE=".codex/delegate-loop-retries"
      RETRY=0
      [ -f "$RETRY_FILE" ] && RETRY=$(cat "$RETRY_FILE" 2>/dev/null || echo 0)
      RETRY=$((RETRY + 1))

      if [ "$RETRY" -ge 2 ]; then
        fail_open "Claude delegate did not complete after retry (task_id=$TASK_ID)"
      fi

      echo "$RETRY" > "$RETRY_FILE"
      block_with_reason \
        "Claude Code has not been run yet. Execute:

\`\`\`
bash .codex/delegate-run-claude.sh
\`\`\`

If the runner is missing, run: bash \"\${PLUGIN_ROOT}/scripts/prepare-delegate.sh\"

Then stop again to begin review." \
        "Delegate Loop [${TASK_ID}] — Waiting for Claude Code"
      exit 0
    fi

    # Recovery: runner missing but spec exists — regenerate
    if [ -f "$SPEC_FILE" ]; then
      prepare_delegate_from_plan || fail_open "recovery prepare failed"
      block_with_reason \
        "Runner was missing and has been regenerated. Execute:

\`\`\`
bash .codex/delegate-run-claude.sh
\`\`\`" \
        "Delegate Loop [${TASK_ID}] — Runner recovered"
      exit 0
    fi

    fail_open "delegate phase missing runner and spec (task_id=$TASK_ID)"
    ;;

  review)
    if [ ! -f "$REVIEW_FILE" ]; then
      block_with_reason \
        "Review not written yet. Analyze the changes and write ${REVIEW_FILE} before stopping." \
        "Delegate Loop [${TASK_ID}] — Review required"
      exit 0
    fi

    if ! grep -qiE '## Result:[[:space:]]*(PASS|FAIL)' "$REVIEW_FILE" 2>/dev/null; then
      block_with_reason \
        "Review must end with exactly one line: \`## Result: PASS\` or \`## Result: FAIL\`" \
        "Delegate Loop [${TASK_ID}] — Review result required"
      exit 0
    fi

    if grep -qiE '## Result:[[:space:]]*FAIL' "$REVIEW_FILE" 2>/dev/null; then
      if [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
        delegate_log "Max iterations reached ($MAX_ITERATIONS), completing with open issues (task_id=$TASK_ID)"
        rm -f "$STATE_FILE" .codex/delegate-loop.lock .codex/delegate-run-claude.sh \
          .codex/claude-prompt.txt .codex/delegate-loop-retries
        printf '{}\n'
        exit 0
      fi

      NEXT=$((ITERATION + 1))
      prepare_delegate_from_review_fail "$NEXT" || fail_open "prepare fix delegate failed"

      block_with_reason \
        "Review found issues (iteration ${NEXT}/${MAX_ITERATIONS}). Run Claude Code to fix:

\`\`\`
bash .codex/delegate-run-claude.sh
\`\`\`

If the runner is missing, run: bash \"\${PLUGIN_ROOT}/scripts/prepare-delegate.sh --fix\"

Then stop to re-review." \
        "Delegate Loop [${TASK_ID}] — Phase 4/4: Fix via Claude Code"
      exit 0
    fi

    delegate_log "Delegate loop complete (task_id=$TASK_ID, iterations=$ITERATION)"
    rm -f "$STATE_FILE" .codex/delegate-loop.lock .codex/delegate-run-claude.sh \
      .codex/claude-prompt.txt .codex/delegate-loop-retries
    printf '{}\n'
    ;;

  fix)
    transition_phase "delegate"
    block_with_reason \
      "Run: bash .codex/delegate-run-claude.sh (or prepare-delegate.sh first if missing)" \
      "Delegate Loop [${TASK_ID}] — Delegate"
    ;;

  *)
    fail_open "unknown phase: $PHASE"
    ;;
esac
