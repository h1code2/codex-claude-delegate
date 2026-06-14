# Codex Claude Delegate

English | [中文](README.zh-CN.md)

Codex Claude Delegate is a Codex plugin that lets Codex supervise implementation while Claude Code writes the code.

## What It Does

| Responsibility | Owner |
| --- | --- |
| Plan scope, files, acceptance criteria, and tests | Codex |
| Implement source changes | Claude Code |
| Review diffs, tests, security, and spec coverage | Codex |
| Fix review failures | Claude Code |

The plugin enforces this flow with Codex skills, a Stop hook, and a direct-edit guard.

## Workflow

```text
@build-loop <task>
  -> Codex writes .codex/delegate-spec.md
  -> Codex prepares .codex/delegate-run-claude.sh
  -> Claude Code implements via claude -p
  -> Codex reviews into reviews/review-<task_id>.md
  -> Claude Code fixes if the review ends with FAIL
```

## Requirements

- macOS
- Codex Desktop or Codex CLI with plugins enabled
- Claude Code CLI at `/usr/local/bin/claude`
- `jq` for hooks and marketplace updates

```bash
brew install jq
npm install -g @anthropic-ai/claude-code
```

## Install

```bash
git clone https://github.com/h1code2/codex-claude-delegate.git
cd codex-claude-delegate
bash scripts/install-mac.sh
```

Restart Codex Desktop after installation.

Verify:

```bash
/Applications/Codex.app/Contents/Resources/codex plugin list | grep codex-claude-delegate
```

Expected result:

```text
codex-claude-delegate@personal-codex-plugins  installed, enabled
```

## Update

```bash
cd /Users/h1code2/Projects/codex-claude-delegate
git pull
bash scripts/install-mac.sh
```

Restart Codex Desktop after updating.

## Enable Codex Features

The installer adds these keys when missing:

```toml
[features]
plugins = true
multi_agent = true
```

If needed, add them manually to `~/.codex/config.toml`.

## Trust Hooks

On first use in a project:

1. Open `/hooks` in Codex.
2. Trust the hooks from `codex-claude-delegate`.

The hooks are required for phase transitions and edit protection.

## Usage

Start a delegated build loop:

```text
@build-loop Add JWT authentication with tests
```

Cancel an active loop:

```text
@cancel-build-loop
```

During the loop:

- Codex writes only `.codex/` and `reviews/` files.
- Claude Code writes source changes.
- Review files must end with `## Result: PASS` or `## Result: FAIL`.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `CLAUDE_BIN` | `/usr/local/bin/claude` | Claude Code CLI path |
| `DELEGATE_MAX_TURNS` | `30` | Max Claude Code turns per delegate run |
| `DELEGATE_TIMEOUT_SECONDS` | `1800` | Max seconds before the runner stops Claude and moves changed work to review |
| `DELEGATE_MAX_ITERATIONS` | `3` | Max review/fix cycles |

Example:

```bash
export CLAUDE_BIN="$(command -v claude)"
export DELEGATE_MAX_TURNS=50
export DELEGATE_TIMEOUT_SECONDS=1800
```

## Local Development Install

For plugin development, copy the marketplace and plugin into a test project:

```bash
mkdir -p /path/to/project/.agents/plugins /path/to/project/plugins
cp .agents/plugins/marketplace.json /path/to/project/.agents/plugins/
cp -R plugins/codex-claude-delegate /path/to/project/plugins/
```

Restart Codex Desktop and install `Claude Delegate` from the Plugins UI.

## Smoke Test

```bash
tmp=$(mktemp -d)
cd "$tmp"
git init
/Users/h1code2/.agents/plugins/codex-claude-delegate/scripts/setup-build-loop.sh "smoke test"
cat > .codex/delegate-spec.md <<'EOF'
# Smoke test

Acceptance criteria:
- state file exists
- prompt file exists
- runner exists
EOF
/Users/h1code2/.agents/plugins/codex-claude-delegate/scripts/prepare-delegate.sh
test -x .codex/delegate-run-claude.sh
```

## Troubleshooting

| Problem | Fix |
| --- | --- |
| Plugin not listed | Restart Codex and run `bash scripts/install-mac.sh` again |
| Hooks not running | Open `/hooks` and trust the plugin hooks |
| Claude runner missing | Run `bash "${PLUGIN_ROOT}/scripts/prepare-delegate.sh"` |
| Claude writes files but does not exit | Let the runner timeout, or interrupt it; if source changed, the next Stop hook moves to review |
| Claude CLI not found | Set `CLAUDE_BIN` or install Claude Code |
| Existing loop blocks new task | Run `@cancel-build-loop` |

## Project Structure

```text
codex-claude-delegate/
├── .agents/plugins/marketplace.json
├── plugins/codex-claude-delegate/
│   ├── .codex-plugin/plugin.json
│   ├── hooks/
│   ├── scripts/
│   └── skills/
├── scripts/install-mac.sh
├── README.md
└── README.zh-CN.md
```

## License

MIT
