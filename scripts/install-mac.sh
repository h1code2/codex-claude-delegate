#!/usr/bin/env bash
# Install codex-claude-delegate for Codex desktop on macOS (personal marketplace)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS_DIR="${HOME}/.agents/plugins"
MARKETPLACE="${AGENTS_DIR}/marketplace.json"
CODEX_CONFIG="${HOME}/.codex/config.toml"
PLUGIN_NAME="codex-claude-delegate"
PLUGIN_SRC="${REPO_ROOT}/plugins/codex-claude-delegate"
PLUGIN_DEST="${AGENTS_DIR}/${PLUGIN_NAME}"
CODEX_CLI="/Applications/Codex.app/Contents/Resources/codex"

echo "Installing ${PLUGIN_NAME} for Codex desktop..."

mkdir -p "${AGENTS_DIR}"

# Codex resolves marketplace paths relative to $HOME, not ~/.agents/plugins/.
# So the entry must be: ./.agents/plugins/codex-claude-delegate
rm -rf "${PLUGIN_DEST}"
ln -sf "${PLUGIN_SRC}" "${PLUGIN_DEST}"

cat > "${MARKETPLACE}" << EOF
{
  "name": "personal-codex-plugins",
  "interface": {
    "displayName": "Personal Codex Plugins"
  },
  "plugins": [
    {
      "name": "${PLUGIN_NAME}",
      "source": {
        "source": "local",
        "path": "./.agents/plugins/${PLUGIN_NAME}"
      },
      "policy": {
        "installation": "AVAILABLE",
        "authentication": "ON_INSTALL"
      },
      "category": "Productivity"
    }
  ]
}
EOF

ensure_config_key() {
  local key="$1"
  local value="$2"
  if [ ! -f "${CODEX_CONFIG}" ]; then
    mkdir -p "$(dirname "${CODEX_CONFIG}")"
    printf '[features]\n%s = %s\n' "$key" "$value" >> "${CODEX_CONFIG}"
    return
  fi
  if grep -qE "^${key}[[:space:]]*=" "${CODEX_CONFIG}" 2>/dev/null; then
    return
  fi
  if grep -qE '^\[features\]' "${CODEX_CONFIG}"; then
    if [ "$(uname)" = "Darwin" ]; then
      sed -i '' "/^\[features\]/a\\
${key} = ${value}
" "${CODEX_CONFIG}"
    else
      sed -i "/^\[features\]/a ${key} = ${value}" "${CODEX_CONFIG}"
    fi
  else
    printf '\n[features]\n%s = %s\n' "$key" "$value" >> "${CODEX_CONFIG}"
  fi
}

ensure_config_key "plugins" "true"
ensure_config_key "multi_agent" "true"

chmod +x "${PLUGIN_SRC}/hooks/"*.sh
chmod +x "${PLUGIN_SRC}/scripts/"*.sh

if [ -x "${CODEX_CLI}" ]; then
  echo ""
  echo "Installing plugin via Codex CLI..."
  if "${CODEX_CLI}" plugin add "${PLUGIN_NAME}@personal-codex-plugins" 2>&1; then
    echo "Plugin installed successfully."
  else
    echo "CLI install failed — restart Codex and install from Plugins UI."
  fi
fi

echo ""
echo "Done."
echo "  Source:      ${PLUGIN_SRC}"
echo "  Link:        ${PLUGIN_DEST}"
echo "  Marketplace: ${MARKETPLACE}"
echo "  Resolved as: \$HOME/.agents/plugins/${PLUGIN_NAME}"
echo ""
echo "Next steps:"
echo "  1. Restart Codex desktop (if not already)"
echo "  2. Verify: codex plugin list | grep codex-claude-delegate"
echo "  3. In a project thread: @build-loop <your task>"
echo "  4. Trust hooks via /hooks on first run"
echo ""
