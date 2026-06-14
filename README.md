# Codex Claude Delegate

A **Codex plugin** that inverts the [claude-review-loop](https://github.com/hamelsmu/claude-review-loop) pattern:

| Role | Agent |
|------|-------|
| Plan, supervise, review | **Codex** (desktop or CLI) |
| Implement all code | **Claude Code** (`claude -p`) |

## Lifecycle

```text
@build-loop <task>
    ↓
Phase 1: plan     — Codex writes .codex/delegate-spec.md
    ↓
prepare-delegate  — bash prepare-delegate.sh (creates runner)
    ↓
Phase 2: delegate — bash .codex/delegate-run-claude.sh
    ↓
Phase 3: review   — Codex writes reviews/review-<id>.md
    ↓
Phase 4: fix      — (if FAIL) Claude fixes, re-review (max 3 iterations)
```

## Requirements

- **Codex** desktop app (macOS) or Codex CLI
- **Claude Code** CLI — already at `/usr/local/bin/claude` on your Mac
- **jq** — `brew install jq` (required by hooks and setup)

## Install (macOS + Codex Desktop)

### Option A — Project-local (recommended for development)

In the repo you want to supervise, copy marketplace + plugins. Codex resolves paths relative to the **repo root**:

```bash
mkdir -p /path/to/your-project/.agents/plugins /path/to/your-project/plugins
cp /Users/h1code2/Projects/codex-claude-delegate/.agents/plugins/marketplace.json \
   /path/to/your-project/.agents/plugins/
cp -R /Users/h1code2/Projects/codex-claude-delegate/plugins/codex-claude-delegate \
   /path/to/your-project/plugins/
```

Restart Codex desktop, open **Plugins**, install **Claude Delegate**.

### Option B — Personal marketplace (all projects)

```bash
bash /Users/h1code2/Projects/codex-claude-delegate/scripts/install-mac.sh
```

Restart Codex if needed. The script registers the marketplace and installs via Codex CLI.

**Important:** Codex resolves personal marketplace `source.path` relative to `$HOME`, not `~/.agents/plugins/`. The correct path is `./.agents/plugins/codex-claude-delegate`, not `./codex-claude-delegate`.

Verify installation:

```bash
/Applications/Codex.app/Contents/Resources/codex plugin list | grep codex-claude-delegate
```

Should show `installed, enabled`.

### Enable features

Ensure `~/.codex/config.toml` includes:

```toml
[features]
plugins = true
multi_agent = true
```

The install script adds these if missing.

### Trust hooks

On first use in a project, open `/hooks` in Codex and **trust** the plugin hooks.

## Usage

In a Codex thread (desktop or CLI):

```text
@build-loop Add JWT authentication with tests
```

Or invoke the skill by name after install. To cancel:

```text
@cancel-build-loop
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_BIN` | `/usr/local/bin/claude` | Claude Code CLI path |
| `DELEGATE_MAX_TURNS` | `30` | Max turns per Claude run |
| `DELEGATE_MAX_ITERATIONS` | `3` | Max review/fix cycles |

## Project structure

```text
codex-claude-delegate/
├── .agents/plugins/marketplace.json
├── plugins/codex-claude-delegate/
│   ├── .codex-plugin/plugin.json
│   ├── skills/build-loop/SKILL.md
│   ├── skills/cancel-build-loop/SKILL.md
│   ├── hooks/stop-hook.sh
│   ├── hooks/block-direct-edits.sh
│   └── scripts/setup-build-loop.sh
├── scripts/install-mac.sh
└── README.md
```

## Inspired by

- [hamelsmu/claude-review-loop](https://github.com/hamelsmu/claude-review-loop) — Stop hook + runner script pattern
- [AlessioZazzarini/claude-codex-collab](https://github.com/AlessioZazzarini/claude-codex-collab) — cross-agent bash bridge
