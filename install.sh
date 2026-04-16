#!/bin/bash
set -e

HOOK_DIR="$HOME/.claude/hooks"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$HOOK_DIR"
cp "$SCRIPT_DIR/langfuse_hook.py" "$HOOK_DIR/langfuse_hook.py"
chmod +x "$HOOK_DIR/langfuse_hook.py"

echo "Installed langfuse_hook.py to $HOOK_DIR"
echo ""
echo "Next steps:"
echo "  1. Add hook to ~/.claude/settings.json (see settings-example-global.json)"
echo "  2. Add env vars to your project's .claude/settings.local.json (see settings-example-project.json)"
echo "  3. Make sure 'uv' is installed: https://docs.astral.sh/uv/"
