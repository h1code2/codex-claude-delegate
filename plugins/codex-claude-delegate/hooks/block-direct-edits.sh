#!/usr/bin/env bash
# Block direct code edits during an active delegate loop.
# Codex may only write under .codex/ and reviews/; all source changes go to Claude Code.

set -euo pipefail

STATE_FILE=".codex/delegate-loop.local.md"

if [ ! -f "$STATE_FILE" ]; then
  exit 0
fi

ACTIVE=$(sed -n 's/^active: *//p' "$STATE_FILE" | head -1)
if [ "$ACTIVE" != "true" ]; then
  exit 0
fi

INPUT=$(cat)

patch_paths_allowed() {
  local command="$1"
  local path
  local found=0

  while IFS= read -r path; do
    [ -z "$path" ] && continue
    found=1
    case "$path" in
      .codex/*|.codex/*/*|reviews/*|reviews/*/*)
        ;;
      *)
        return 1
        ;;
    esac
  done < <(printf '%s\n' "$command" | sed -nE 's/^\*\*\* (Add|Update|Delete) File: (.+)$/\2/p')

  [ "$found" -eq 1 ]
}

if command -v jq >/dev/null 2>&1; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.file_path // empty' 2>/dev/null || true)
else
  COMMAND=""
  FILE_PATH=""
fi

if [ -n "$COMMAND" ] && patch_paths_allowed "$COMMAND"; then
  exit 0
fi

if [ -n "$FILE_PATH" ]; then
  case "$FILE_PATH" in
    .codex/*|reviews/*|*/.codex/*|*/reviews/*)
      exit 0
      ;;
  esac
fi

PHASE=$(sed -n 's/^phase: *//p' "$STATE_FILE" | head -1)

REASON="Delegate loop active (phase: ${PHASE}). Do not edit source code directly. "
REASON+="Write specs and reviews under .codex/ or reviews/, and delegate implementation to Claude Code via:"
REASON+=" bash .codex/delegate-run-claude.sh"

jq -n --arg r "$REASON" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}' 2>/dev/null \
  || jq -n --arg r "$REASON" '{decision: "block", reason: $r}' 2>/dev/null \
  || printf '{"decision":"block","reason":"%s"}\n' "$REASON"
exit 0
