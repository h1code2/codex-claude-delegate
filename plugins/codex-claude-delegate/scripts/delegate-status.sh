#!/usr/bin/env bash
set -euo pipefail

STATE_FILE=".codex/delegate-loop.local.md"

field() {
  sed -n "s/^${1}: *//p" "$STATE_FILE" 2>/dev/null | head -1
}

exists() {
  [ -e "$1" ] && echo "yes" || echo "no"
}

echo "Delegate status"
echo "==============="

if [ ! -f "$STATE_FILE" ]; then
  echo "active: no"
  echo "next: @build-loop <task>"
  exit 0
fi

active="$(field active)"
phase="$(field phase)"
task_id="$(field task_id)"
iteration="$(field iteration)"
max_iterations="$(field max_iterations)"

echo "active: ${active:-unknown}"
echo "phase: ${phase:-unknown}"
echo "task_id: ${task_id:-unknown}"
echo "iteration: ${iteration:-?}/${max_iterations:-?}"
echo "spec: $(exists .codex/delegate-spec.md)"
echo "prompt: $(exists .codex/claude-prompt.txt)"
echo "runner: $(exists .codex/delegate-run-claude.sh)"
echo "summary: $(exists .codex/delegate-summary.md)"
echo "done_marker: $(exists .codex/delegate-claude-done)"
echo "needs_review_marker: $(exists .codex/delegate-claude-needs-review)"
echo "interrupted_marker: $(exists .codex/delegate-claude-interrupted)"

case "$phase" in
  plan)
    if [ -f .codex/delegate-spec.md ]; then
      echo "next: bash \"\${PLUGIN_ROOT}/scripts/prepare-delegate.sh\""
    else
      echo "next: clarify requirements if needed, then write .codex/delegate-spec.md"
    fi
    ;;
  delegate)
    if [ -f .codex/delegate-claude-done ] || [ -f .codex/delegate-claude-needs-review ]; then
      echo "next: stop the turn so the hook moves to review"
    elif [ -x .codex/delegate-run-claude.sh ]; then
      echo "next: bash .codex/delegate-run-claude.sh"
    else
      echo "next: bash \"\${PLUGIN_ROOT}/scripts/prepare-delegate.sh\""
    fi
    ;;
  review)
    echo "next: complete reviews/review-${task_id}.md with ## Result: PASS or ## Result: FAIL"
    ;;
  *)
    echo "next: @delegate-recover"
    ;;
esac
