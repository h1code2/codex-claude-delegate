#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=delegate-lib.sh
source "${SCRIPT_DIR}/delegate-lib.sh"

has_source_changes() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git status --porcelain 2>/dev/null | awk '
    {
      path = substr($0, 4)
      if (index(path, " -> ") > 0) {
        split(path, parts, " -> ")
        path = parts[2]
      }
      if (path !~ /^\.codex(\/|$)/ && path !~ /^reviews(\/|$)/) {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  '
}

restore_state() {
  if [ ! -f "$STATE_FILE" ] && [ -f "${STATE_FILE}.runner-backup" ]; then
    cp "${STATE_FILE}.runner-backup" "$STATE_FILE"
    echo "restored state from runner backup"
  fi
}

restore_state

if [ ! -f "$STATE_FILE" ]; then
  echo "No active delegate state and no runner backup found."
  exit 0
fi

load_delegate_state

case "$PHASE" in
  plan)
    if [ -f "$SPEC_FILE" ]; then
      prepare_delegate_from_plan
      echo "Recovered: prepared delegate runner from existing spec."
    else
      echo "Plan phase is active. Write ${SPEC_FILE}, then prepare delegation."
    fi
    ;;
  delegate)
    if [ -f .codex/delegate-claude-done ]; then
      transition_phase "review"
      write_review_template
      rm -f .codex/delegate-run-claude.sh .codex/delegate-claude-done .codex/delegate-loop-retries
      echo "Recovered: completed delegate moved to review."
    elif [ -f .codex/delegate-claude-needs-review ] || { [ -s .codex/delegate-claude-output.log ] && has_source_changes; }; then
      touch .codex/delegate-claude-needs-review
      transition_phase "review"
      write_review_template
      rm -f .codex/delegate-run-claude.sh .codex/delegate-loop-retries
      echo "Recovered: source changes moved to review."
    elif [ -f "$SPEC_FILE" ]; then
      prepare_delegate_from_plan
      echo "Recovered: delegate runner regenerated."
    else
      echo "Cannot recover delegate phase: missing ${SPEC_FILE}."
      exit 1
    fi
    ;;
  review)
    if [ -f "$REVIEW_FILE" ] && grep -qiE '## Result:[[:space:]]*FAIL' "$REVIEW_FILE"; then
      NEXT=$((ITERATION + 1))
      prepare_delegate_from_review_fail "$NEXT"
      echo "Recovered: FAIL review prepared for fix delegation."
    elif [ -f "$REVIEW_FILE" ]; then
      echo "Review exists. Ensure it ends with ## Result: PASS or ## Result: FAIL."
    else
      write_review_template
      echo "Recovered: review template created at ${REVIEW_FILE}."
    fi
    ;;
  *)
    echo "Unsupported phase: ${PHASE}"
    exit 1
    ;;
esac
