#!/usr/bin/env bash
# Prepare Claude Code delegation — generates prompt + runner without waiting for Stop hook.
#
# Run this explicitly after writing delegate-spec.md (or when runner is missing).
# Stop hook also calls the same logic, but Codex desktop often continues in the
# same turn without triggering Stop, so this script is the reliable path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=delegate-lib.sh
source "${SCRIPT_DIR}/delegate-lib.sh"

MODE="${1:-auto}"

load_delegate_state
rm -f .codex/delegate-loop-retries

case "$MODE" in
  --help|-h)
    cat << 'HELP'
Usage: prepare-delegate.sh [auto|--plan|--fix]

Generates:
  .codex/claude-prompt.txt
  .codex/delegate-run-claude.sh

Modes:
  auto   Infer from current phase (default)
  --plan Force plan → delegate preparation (requires delegate-spec.md)
  --fix  Force review-fail → delegate preparation (requires FAIL review)
HELP
    exit 0
    ;;
  --plan)
    prepare_delegate_from_plan
    ;;
  --fix)
    NEXT=$((ITERATION + 1))
    prepare_delegate_from_review_fail "$NEXT"
    ;;
  auto|*)
    case "$PHASE" in
      plan)
        prepare_delegate_from_plan
        ;;
      delegate)
        if [ -f ".codex/delegate-claude-done" ]; then
          echo "Claude delegate already completed. Stop your turn to enter review."
          exit 0
        fi
        if [ -f ".codex/delegate-run-claude.sh" ] && [ -f ".codex/claude-prompt.txt" ]; then
          echo "Runner already exists."
          exit 0
        fi
        if [ -f ".codex/claude-prompt.txt" ]; then
          write_claude_runner
        elif [ -f "$SPEC_FILE" ]; then
          prepare_delegate_from_plan
        else
          echo "Error: Cannot prepare delegate — missing spec and prompt." >&2
          exit 1
        fi
        ;;
      review)
        if [ -f "$REVIEW_FILE" ] && grep -qiE '## Result:[[:space:]]*FAIL' "$REVIEW_FILE"; then
          NEXT=$((ITERATION + 1))
          prepare_delegate_from_review_fail "$NEXT"
        else
          echo "Error: Phase is review. Write review with FAIL before preparing fix delegate." >&2
          exit 1
        fi
        ;;
      *)
        echo "Error: Unsupported phase for prepare-delegate: ${PHASE}" >&2
        exit 1
        ;;
    esac
    ;;
esac

delegate_log "prepare-delegate.sh completed (phase=$(parse_field phase), task_id=${TASK_ID})"

echo ""
echo "Delegate runner ready"
echo "  Prompt:  .codex/claude-prompt.txt"
echo "  Runner:  .codex/delegate-run-claude.sh"
echo "  Phase:   $(parse_field phase)"
echo ""
echo "Next: bash .codex/delegate-run-claude.sh"
echo ""
