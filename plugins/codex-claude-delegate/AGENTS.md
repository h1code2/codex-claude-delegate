# Agent guidelines — codex-claude-delegate plugin

This repository packages a Codex plugin. When modifying it:

- Keep **Codex as supervisor only** — no business logic in plugin shell scripts beyond orchestration
- **Claude Code** owns all source edits via `claude -p`
- Follow the Stop hook phase machine in `hooks/stop-hook.sh`
- Test on macOS with Codex desktop + `/usr/local/bin/claude`
- Fail-open on hook errors — never trap users in a broken loop
- Review files must end with `## Result: PASS` or `## Result: FAIL`

## Testing locally

1. Copy marketplace + plugins into a test repo
2. Restart Codex desktop
3. Trust hooks via `/hooks`
4. Run `@build-loop Implement a hello world CLI with tests`
