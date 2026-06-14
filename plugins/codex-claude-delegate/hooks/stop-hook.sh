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

set -euo pipefail

LOG_FILE=".codex/delegate-loop.log"

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

fail_open() {
  log "ERROR: $* — failing open"
  rm -f .codex/delegate-loop.local.md .codex/delegate-loop.lock \
    .codex/delegate-run-claude.sh .codex/claude-prompt.txt .codex/delegate-loop-retries \
    .codex/delegate-claude-done
  printf '{}\n'
  exit 0
}

trap 'fail_open "hook exited via ERR trap (line $LINENO)"' ERR

HOOK_INPUT=$(cat)
STATE_FILE=".codex/delegate-loop.local.md"

if [ ! -f "$STATE_FILE" ]; then
  printf '{}\n'
  exit 0
fi

parse_field() {
  sed -n "s/^${1}: *//p" "$STATE_FILE" | head -1
}

task_body() {
  awk '/^---$/{n++; next} n>=2' "$STATE_FILE"
}

ACTIVE=$(parse_field "active")
PHASE=$(parse_field "phase")
TASK_ID=$(parse_field "task_id")
ITERATION=$(parse_field "iteration")
MAX_ITERATIONS=$(parse_field "max_iterations")

if [ "$ACTIVE" != "true" ]; then
  rm -f "$STATE_FILE"
  printf '{}\n'
  exit 0
fi

if ! echo "$TASK_ID" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$'; then
  fail_open "invalid task_id format: $TASK_ID"
fi

ITERATION="${ITERATION:-1}"
MAX_ITERATIONS="${MAX_ITERATIONS:-3}"

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
  log "Phase transitioned to: $new_phase (iteration=${new_iteration:-$ITERATION})"
}

write_claude_runner() {
  local prompt_file=".codex/claude-prompt.txt"
  local runner=".codex/delegate-run-claude.sh"
  local claude_bin="${CLAUDE_BIN:-/usr/local/bin/claude}"
  local max_turns="${DELEGATE_MAX_TURNS:-30}"

  if [ ! -f "$prompt_file" ]; then
    fail_open "missing prompt file: $prompt_file"
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

block_with_reason() {
  local reason="$1"
  local system_msg="$2"
  jq -n --arg r "$reason" --arg s "$system_msg" \
    '{decision: "block", reason: $r, systemMessage: $s}' 2>/dev/null \
    || printf '{"decision":"block","reason":"%s","systemMessage":"%s"}\n' "$reason" "$system_msg"
}

REVIEW_FILE="reviews/review-${TASK_ID}.md"
SPEC_FILE=".codex/delegate-spec.md"

case "$PHASE" in
  plan)
    if [ ! -f "$SPEC_FILE" ]; then
      block_with_reason \
        "Planning is not complete. Write the implementation spec to ${SPEC_FILE} (scope, files, acceptance criteria, test plan). Do not edit source code — Claude Code will implement." \
        "Delegate Loop [${TASK_ID}] — Phase 1/4: Planning"
      exit 0
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

    write_claude_runner
    transition_phase "delegate"

    block_with_reason \
      "Planning complete. Run Claude Code to implement (use a long Bash timeout, e.g. 600000ms):

\`\`\`
bash .codex/delegate-run-claude.sh
\`\`\`

After Claude finishes, stop again to enter the review phase." \
      "Delegate Loop [${TASK_ID}] — Phase 2/4: Delegate to Claude Code"
    ;;

  delegate)
    if [ -f ".codex/delegate-claude-done" ]; then
      rm -f .codex/delegate-run-claude.sh .codex/delegate-claude-done .codex/delegate-loop-retries
      if [ "$ITERATION" -gt 1 ]; then
        rm -f "$REVIEW_FILE"
      fi
      transition_phase "review"

      block_with_reason \
        "Implementation phase complete. Perform an independent review:

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

Then stop again to begin review." \
        "Delegate Loop [${TASK_ID}] — Waiting for Claude Code"
      exit 0
    fi

    fail_open "delegate phase missing runner script (task_id=$TASK_ID)"
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
        log "Max iterations reached ($MAX_ITERATIONS), completing with open issues (task_id=$TASK_ID)"
        rm -f "$STATE_FILE" .codex/delegate-loop.lock .codex/delegate-run-claude.sh \
          .codex/claude-prompt.txt .codex/delegate-loop-retries
        printf '{}\n'
        exit 0
      fi

      NEXT=$((ITERATION + 1))
      cat > .codex/claude-prompt.txt << PROMPT_EOF
You are Claude Code fixing issues from a Codex review. Implement all agreed fixes.

## Original task
$(task_body)

## Spec
$(cat "$SPEC_FILE" 2>/dev/null || echo "(see prior implementation)")

## Review (iteration ${NEXT})
$(cat "$REVIEW_FILE")

## Rules
- Address critical and high severity items first
- Add or update tests for each fix
- Run relevant tests before finishing
PROMPT_EOF

      write_claude_runner
      transition_phase "delegate" "$NEXT"

      block_with_reason \
        "Review found issues (iteration ${NEXT}/${MAX_ITERATIONS}). Run Claude Code to fix:

\`\`\`
bash .codex/delegate-run-claude.sh
\`\`\`

Then stop to re-review." \
        "Delegate Loop [${TASK_ID}] — Phase 4/4: Fix via Claude Code"
      exit 0
    fi

    log "Delegate loop complete (task_id=$TASK_ID, iterations=$ITERATION)"
    rm -f "$STATE_FILE" .codex/delegate-loop.lock .codex/delegate-run-claude.sh \
      .codex/claude-prompt.txt .codex/delegate-loop-retries
    printf '{}\n'
    ;;

  fix)
    # Legacy phase name — treat as delegate
    transition_phase "delegate"
    block_with_reason \
      "Run Claude Code: bash .codex/delegate-run-claude.sh" \
      "Delegate Loop [${TASK_ID}] — Delegate"
    ;;

  *)
    fail_open "unknown phase: $PHASE"
    ;;
esac
