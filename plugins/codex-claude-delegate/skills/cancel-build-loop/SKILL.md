---
name: cancel-build-loop
description: Cancel an active Codex delegate loop
---

Check for an active loop:

```bash
test -f .codex/delegate-loop.local.md && echo ACTIVE || echo NONE
```

If active, read `.codex/delegate-loop.local.md` for phase and task_id, then remove state artifacts:

```bash
rm -f .codex/delegate-loop.local.md \
      .codex/delegate-loop.lock \
      .codex/delegate-run-claude.sh \
      .codex/claude-prompt.txt \
      .codex/delegate-spec.md \
      .codex/delegate-claude-done \
      .codex/delegate-claude-interrupted \
      .codex/delegate-claude-needs-review \
      .codex/delegate-claude-output.log \
      .codex/delegate-loop.local.md.runner-backup \
      .codex/delegate-loop-retries
```

Report what was cancelled. If none was active, say so.
