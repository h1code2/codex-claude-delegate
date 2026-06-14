#!/usr/bin/env bash
# Shared delegate loop helpers (sourced by stop-hook and prepare-delegate)
set -euo pipefail

STATE_FILE=".codex/delegate-loop.local.md"
LOG_FILE=".codex/delegate-loop.log"
SPEC_FILE=".codex/delegate-spec.md"

delegate_log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

parse_field() {
  sed -n "s/^${1}: *//p" "$STATE_FILE" | head -1
}

task_body() {
  awk '/^---$/{n++; next} n>=2' "$STATE_FILE"
}

load_delegate_state() {
  if [ ! -f "$STATE_FILE" ]; then
    echo "Error: No active delegate loop. Run @build-loop first." >&2
    return 1
  fi

  ACTIVE=$(parse_field "active")
  PHASE=$(parse_field "phase")
  TASK_ID=$(parse_field "task_id")
  ITERATION=$(parse_field "iteration")
  MAX_ITERATIONS=$(parse_field "max_iterations")

  if [ "$ACTIVE" != "true" ]; then
    echo "Error: Delegate loop is not active." >&2
    return 1
  fi

  if ! echo "$TASK_ID" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$'; then
    echo "Error: Invalid task_id in state file." >&2
    return 1
  fi

  ITERATION="${ITERATION:-1}"
  MAX_ITERATIONS="${MAX_ITERATIONS:-3}"
  REVIEW_FILE="reviews/review-${TASK_ID}.md"
}

transition_phase() {
  local new_phase="$1"
  local new_iteration="${2:-}"
  local temp="${STATE_FILE}.tmp.$$"

  awk -v np="$new_phase" -v ni="$new_iteration" '{
    if ($0 ~ /^phase:/) { print "phase: " np; next }
    if (ni != "" && $0 ~ /^iteration:/) { print "iteration: " ni; next }
    print
  }' "$STATE_FILE" > "$temp"

  mv "$temp" "$STATE_FILE"
  delegate_log "Phase transitioned to: $new_phase (iteration=${new_iteration:-$ITERATION})"
}

write_implement_prompt() {
  if [ ! -f "$SPEC_FILE" ]; then
    echo "Error: Missing ${SPEC_FILE}. Complete planning first." >&2
    return 1
  fi

  mkdir -p .codex reviews
  cat > .codex/claude-prompt.txt << PROMPT_EOF
You are Claude Code acting as the implementation engineer. Codex has planned this work; you execute all code changes.

## Task
$(task_body)

## Spec (from Codex)
$(cat "$SPEC_FILE")

## Rules
- Implement the full spec with clean, tested code
- Run relevant tests before finishing
- Do not modify .codex/ or reviews/ unless necessary for the task
- Commit is optional unless the spec requires it
PROMPT_EOF
}

write_fix_prompt() {
  local next_iteration="$1"

  if [ ! -f "$REVIEW_FILE" ]; then
    echo "Error: Missing ${REVIEW_FILE}." >&2
    return 1
  fi

  cat > .codex/claude-prompt.txt << PROMPT_EOF
You are Claude Code fixing issues from a Codex review. Implement all agreed fixes.

## Original task
$(task_body)

## Spec
$(cat "$SPEC_FILE" 2>/dev/null || echo "(see prior implementation)")

## Review (iteration ${next_iteration})
$(cat "$REVIEW_FILE")

## Rules
- Address critical and high severity items first
- Add or update tests for each fix
- Run relevant tests before finishing
PROMPT_EOF
}

write_claude_runner() {
  local prompt_file=".codex/claude-prompt.txt"
  local runner=".codex/delegate-run-claude.sh"
  local claude_bin="${CLAUDE_BIN:-/usr/local/bin/claude}"
  local max_turns="${DELEGATE_MAX_TURNS:-30}"

  if [ ! -f "$prompt_file" ]; then
    echo "Error: Missing ${prompt_file}." >&2
    return 1
  fi

  cat > "$runner" << RUNNER_EOF
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE=".codex/delegate-loop.log"
log() { echo "[\$(date -u +"%Y-%m-%dT%H:%M:%SZ")] \$*" >> "\$LOG_FILE"; }

PROMPT_FILE=".codex/claude-prompt.txt"
CLAUDE_BIN="${claude_bin}"
MAX_TURNS="${max_turns}"

if [ ! -x "\$CLAUDE_BIN" ] && ! command -v "\$CLAUDE_BIN" >/dev/null 2>&1; then
  echo "ERROR: Claude Code CLI not found at \$CLAUDE_BIN" >&2
  echo "Install: npm install -g @anthropic-ai/claude-code" >&2
  exit 1
fi

if [ ! -f "\$PROMPT_FILE" ]; then
  echo "ERROR: prompt file missing: \$PROMPT_FILE" >&2
  exit 1
fi

log "Starting Claude Code delegate (task_id=${TASK_ID})"
START=\$(date +%s)

set +e
"\$CLAUDE_BIN" -p "\$(cat "\$PROMPT_FILE")" \\
  --allowedTools "Bash,Read,Write,Edit,Glob,Grep" \\
  --max-turns "\$MAX_TURNS" \\
  2>&1 | tee -a "\$LOG_FILE"
EXIT=\${PIPESTATUS[0]}
set -e

ELAPSED=\$(( \$(date +%s) - START ))
log "Claude Code finished (exit=\$EXIT, elapsed=\${ELAPSED}s)"
if [ "\$EXIT" -eq 0 ]; then
  touch .codex/delegate-claude-done
fi
exit "\$EXIT"
RUNNER_EOF

  chmod +x "$runner"
}

prepare_delegate_from_plan() {
  rm -f .codex/delegate-claude-done .codex/delegate-loop-retries
  write_implement_prompt
  write_claude_runner
  if [ "$PHASE" = "plan" ]; then
    transition_phase "delegate"
  fi
}

prepare_delegate_from_review_fail() {
  local next_iteration="$1"

  if ! grep -qiE '## Result:[[:space:]]*FAIL' "$REVIEW_FILE" 2>/dev/null; then
    echo "Error: Review does not contain '## Result: FAIL'." >&2
    return 1
  fi

  write_fix_prompt "$next_iteration"
  write_claude_runner
  transition_phase "delegate" "$next_iteration"
  rm -f .codex/delegate-claude-done .codex/delegate-loop-retries
}
