#!/usr/bin/env bash
set -euo pipefail

# Delegate Loop — Setup Script

show_help() {
  cat << 'HELP'
Usage: setup-build-loop.sh "<task description>"

Starts a delegate loop:
  1. Codex plans the work (spec only, no source edits)
  2. Claude Code implements via claude -p
  3. Codex reviews the diff
  4. If needed, Claude Code fixes and Codex re-reviews

Environment variables:
  CLAUDE_BIN              Path to claude CLI (default: /usr/local/bin/claude)
  DELEGATE_MAX_TURNS      Max agent turns for Claude (default: 30)
  DELEGATE_MAX_ITERATIONS Max review/fix cycles (default: 3)
HELP
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  show_help
  exit 0
fi

PROMPT="${*:-}"
if [ -z "$PROMPT" ]; then
  echo "Error: No task description provided." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required (brew install jq)" >&2
  exit 1
fi

CLAUDE_BIN="${CLAUDE_BIN:-/usr/local/bin/claude}"
if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
  echo "Warning: Claude Code CLI not found at $CLAUDE_BIN"
  echo "Install: npm install -g @anthropic-ai/claude-code"
fi

if [ -f ".codex/delegate-loop.local.md" ]; then
  echo "Error: A delegate loop is already active. Use @cancel-build-loop first." >&2
  exit 1
fi

if command -v openssl >/dev/null 2>&1; then
  RAND_HEX=$(openssl rand -hex 3)
else
  RAND_HEX=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
fi

TASK_ID="$(date +%Y%m%d-%H%M%S)-${RAND_HEX}"
MAX_ITER="${DELEGATE_MAX_ITERATIONS:-3}"

rm -f .codex/delegate-loop.lock .codex/delegate-claude-done

mkdir -p .codex reviews

cat > .codex/delegate-loop.local.md << STATE_EOF
---
active: true
phase: plan
task_id: ${TASK_ID}
iteration: 1
max_iterations: ${MAX_ITER}
started_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
---

${PROMPT}
STATE_EOF

echo ""
echo "Delegate Loop activated"
echo "  ID:           ${TASK_ID}"
echo "  Phase:        1/4 — Plan (Codex writes spec)"
echo "  Spec:         .codex/delegate-spec.md"
echo "  Review:       reviews/review-${TASK_ID}.md"
echo "  Claude:       ${CLAUDE_BIN}"
echo ""
echo "  Use @cancel-build-loop to abort."
echo ""
