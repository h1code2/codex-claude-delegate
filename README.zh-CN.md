# Codex Claude Delegate

[English](README.md) | 中文

Codex Claude Delegate 是一个 Codex 插件，用于让 Codex 负责规划和审查，让 Claude Code 负责实际代码实现。

## 功能

| 职责 | 执行者 |
| --- | --- |
| 规划范围、文件、验收标准和测试计划 | Codex |
| 修改源码并实现功能 | Claude Code |
| 审查 diff、测试、安全性和需求覆盖 | Codex |
| 根据审查结果修复问题 | Claude Code |

插件通过 Codex skills、Stop hook 和直接编辑保护来约束这个流程。

## 工作流

```text
@build-loop <任务>
  -> Codex 编写 .codex/delegate-spec.md
  -> Codex 生成 .codex/delegate-run-claude.sh
  -> Claude Code 通过 claude -p 实现代码
  -> Codex 审查并写入 reviews/review-<task_id>.md
  -> 如果审查结果为 FAIL，则 Claude Code 继续修复
```

## 依赖

- macOS
- 已启用插件功能的 Codex Desktop 或 Codex CLI
- Claude Code CLI，默认路径为 `/usr/local/bin/claude`
- `jq`，用于 hooks 和 marketplace 更新

```bash
brew install jq
npm install -g @anthropic-ai/claude-code
```

## 安装

```bash
git clone https://github.com/h1code2/codex-claude-delegate.git
cd codex-claude-delegate
bash scripts/install-mac.sh
```

安装后重启 Codex Desktop。

验证安装：

```bash
/Applications/Codex.app/Contents/Resources/codex plugin list | grep codex-claude-delegate
```

预期结果：

```text
codex-claude-delegate@personal-codex-plugins  installed, enabled
```

## 更新

```bash
cd /Users/h1code2/Projects/codex-claude-delegate
git pull
bash scripts/install-mac.sh
```

更新后重启 Codex Desktop。

## 启用 Codex 功能

安装脚本会在缺失时添加以下配置：

```toml
[features]
plugins = true
multi_agent = true
```

如有需要，也可以手动写入 `~/.codex/config.toml`。

## 信任 Hooks

第一次在项目中使用时：

1. 在 Codex 中打开 `/hooks`。
2. 信任 `codex-claude-delegate` 的 hooks。

hooks 用于状态流转和源码直接编辑保护。

## 使用

启动委托构建循环：

```text
@build-loop Add JWT authentication with tests
```

取消当前循环：

```text
@cancel-build-loop
```

循环过程中：

- Codex 只写 `.codex/` 和 `reviews/`。
- Claude Code 负责写源码。
- 审查文件必须以 `## Result: PASS` 或 `## Result: FAIL` 结尾。

## 配置

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `CLAUDE_BIN` | `/usr/local/bin/claude` | Claude Code CLI 路径 |
| `DELEGATE_MAX_TURNS` | `30` | 每次 Claude Code 执行的最大 turn 数 |
| `DELEGATE_MAX_ITERATIONS` | `3` | 最大审查/修复循环次数 |

示例：

```bash
export CLAUDE_BIN="$(command -v claude)"
export DELEGATE_MAX_TURNS=50
```

## 本地开发安装

如果要在测试项目里开发插件，可以复制 marketplace 和插件目录：

```bash
mkdir -p /path/to/project/.agents/plugins /path/to/project/plugins
cp .agents/plugins/marketplace.json /path/to/project/.agents/plugins/
cp -R plugins/codex-claude-delegate /path/to/project/plugins/
```

重启 Codex Desktop，然后在 Plugins UI 中安装 `Claude Delegate`。

## 冒烟测试

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

## 常见问题

| 问题 | 处理方式 |
| --- | --- |
| 插件列表里看不到 | 重启 Codex，并重新运行 `bash scripts/install-mac.sh` |
| hooks 没有执行 | 打开 `/hooks` 并信任插件 hooks |
| Claude runner 不存在 | 运行 `bash "${PLUGIN_ROOT}/scripts/prepare-delegate.sh"` |
| 找不到 Claude CLI | 设置 `CLAUDE_BIN` 或安装 Claude Code |
| 已有 loop 阻止新任务 | 运行 `@cancel-build-loop` |

## 项目结构

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

## 许可证

MIT
