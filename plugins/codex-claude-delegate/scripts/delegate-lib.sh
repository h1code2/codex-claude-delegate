#!/usr/bin/env bash
# Shared delegate loop helpers (sourced by stop-hook and prepare-delegate)
set -euo pipefail

STATE_FILE=".codex/delegate-loop.local.md"
LOG_FILE=".codex/delegate-loop.log"
SPEC_FILE=".codex/delegate-spec.md"
SUMMARY_FILE=".codex/delegate-summary.md"

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

write_review_template() {
  mkdir -p reviews
  if [ -f "$REVIEW_FILE" ]; then
    return 0
  fi

  cat > "$REVIEW_FILE" << REVIEW_EOF
# Delegate Review — ${TASK_ID}

## Context

- Phase: review
- Iteration: ${ITERATION}/${MAX_ITERATIONS}
- Spec: ${SPEC_FILE}
- Summary: ${SUMMARY_FILE}

## Checks

- [ ] Reviewed \`git diff\`
- [ ] Reviewed \`git diff --cached\`
- [ ] Ran or evaluated relevant tests
- [ ] Checked acceptance criteria
- [ ] Checked security and error handling

## Findings

- None yet.

## Result: FAIL
REVIEW_EOF
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
  local timeout_seconds="${DELEGATE_TIMEOUT_SECONDS:-1800}"

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
TIMEOUT_SECONDS="${timeout_seconds}"
STATE_FILE=".codex/delegate-loop.local.md"
STATE_BACKUP=".codex/delegate-loop.local.md.runner-backup"
OUTPUT_FILE=".codex/delegate-claude-output.log"
SUMMARY_FILE=".codex/delegate-summary.md"
INTERRUPTED_MARKER=".codex/delegate-claude-interrupted"
NEEDS_REVIEW_MARKER=".codex/delegate-claude-needs-review"
CLAUDE_PID=""
TAIL_PID=""

if [ ! -x "\$CLAUDE_BIN" ] && ! command -v "\$CLAUDE_BIN" >/dev/null 2>&1; then
  echo "ERROR: Claude Code CLI not found at \$CLAUDE_BIN" >&2
  echo "Install: npm install -g @anthropic-ai/claude-code" >&2
  exit 1
fi

if [ ! -f "\$PROMPT_FILE" ]; then
  echo "ERROR: prompt file missing: \$PROMPT_FILE" >&2
  exit 1
fi

mkdir -p .codex
rm -f "\$INTERRUPTED_MARKER" "\$NEEDS_REVIEW_MARKER"
if [ -f "\$STATE_FILE" ]; then
  cp "\$STATE_FILE" "\$STATE_BACKUP"
fi
: > "\$OUTPUT_FILE"

restore_state_if_missing() {
  if [ ! -f "\$STATE_FILE" ] && [ -f "\$STATE_BACKUP" ]; then
    cp "\$STATE_BACKUP" "\$STATE_FILE"
    log "Restored missing delegate state from runner backup"
  fi
}

has_source_changes() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git status --porcelain 2>/dev/null | awk '
    {
      path = substr(\$0, 4)
      if (index(path, " -> ") > 0) {
        split(path, parts, " -> ")
        path = parts[2]
      }
      if (path !~ /^\\.codex(\\/|$)/ && path !~ /^reviews(\\/|$)/) {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  '
}

mark_interrupted() {
  local reason="\$1"
  touch "\$INTERRUPTED_MARKER"
  restore_state_if_missing
  if has_source_changes; then
    touch "\$NEEDS_REVIEW_MARKER"
    log "Claude delegate \$reason; source changes detected, review required"
  else
    log "Claude delegate \$reason; no source changes detected"
  fi
}

write_summary() {
  local exit_code="\$1"
  local elapsed="\$2"
  local status="completed"
  if [ "\$exit_code" -ne 0 ]; then
    status="failed"
  fi

  {
    echo "# Delegate Run Summary"
    echo ""
    echo "- Task ID: ${TASK_ID}"
    echo "- Status: \${status}"
    echo "- Exit code: \${exit_code}"
    echo "- Elapsed seconds: \${elapsed}"
    echo "- Prompt: \${PROMPT_FILE}"
    echo "- Output log: \${OUTPUT_FILE}"
    echo ""
    echo "## Changed Files"
    echo ""
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git status --short 2>/dev/null | sed 's/^/- /' || true
    else
      echo "- Not a git repository"
    fi
    echo ""
    echo "## Recent Output"
    echo ""
    echo '~~~text'
    tail -n 80 "\$OUTPUT_FILE" 2>/dev/null || true
    echo '~~~'
  } > "\$SUMMARY_FILE"
}

cleanup_children() {
  [ -n "\$TAIL_PID" ] && kill "\$TAIL_PID" >/dev/null 2>&1 || true
  if [ -n "\$CLAUDE_PID" ] && kill -0 "\$CLAUDE_PID" >/dev/null 2>&1; then
    kill "\$CLAUDE_PID" >/dev/null 2>&1 || true
    sleep 1
    kill -9 "\$CLAUDE_PID" >/dev/null 2>&1 || true
  fi
}

on_signal() {
  cleanup_children
  mark_interrupted "interrupted"
  exit 130
}

trap on_signal INT TERM

log "Starting Claude Code delegate (task_id=${TASK_ID})"
START=\$(date +%s)

set +e
"\$CLAUDE_BIN" -p "\$(cat "\$PROMPT_FILE")" \\
  --allowedTools "Bash,Read,Write,Edit,Glob,Grep" \\
  --max-turns "\$MAX_TURNS" \\
  > "\$OUTPUT_FILE" 2>&1 &
CLAUDE_PID=\$!

tail -n +1 -f "\$OUTPUT_FILE" 2>/dev/null &
TAIL_PID=\$!

EXIT=0
while kill -0 "\$CLAUDE_PID" >/dev/null 2>&1; do
  NOW=\$(date +%s)
  if [ "\$TIMEOUT_SECONDS" -gt 0 ] && [ \$((NOW - START)) -ge "\$TIMEOUT_SECONDS" ]; then
    cleanup_children
    wait "\$CLAUDE_PID" >/dev/null 2>&1
    EXIT=124
    mark_interrupted "timed out after \${TIMEOUT_SECONDS}s"
    break
  fi
  sleep 2
done

if [ "\$EXIT" -eq 0 ]; then
  wait "\$CLAUDE_PID"
  EXIT=\$?
fi

if [ -n "\$TAIL_PID" ]; then
  sleep 0.2
  kill "\$TAIL_PID" >/dev/null 2>&1 || true
  wait "\$TAIL_PID" >/dev/null 2>&1 || true
fi

cat "\$OUTPUT_FILE" >> "\$LOG_FILE"
set -e

ELAPSED=\$(( \$(date +%s) - START ))
log "Claude Code finished (exit=\$EXIT, elapsed=\${ELAPSED}s)"
restore_state_if_missing
if [ "\$EXIT" -eq 0 ]; then
  touch .codex/delegate-claude-done
else
  mark_interrupted "exited with code \$EXIT"
fi
write_summary "\$EXIT" "\$ELAPSED"
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
