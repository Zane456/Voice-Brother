#!/bin/bash
# Voice Brother - 动态热词 extension 卸载脚本
# 移除 launchd job + venv。**不会**清除 state/ 下的数据。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"
PLIST_LABEL="com.voicebrother.dynamic-hotwords"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

if [[ -f "$PLIST_DEST" ]]; then
  echo "▸ unloading launchd job"
  launchctl unload "$PLIST_DEST" 2>/dev/null || true
  rm "$PLIST_DEST"
fi

if [[ -d "$VENV_DIR" ]]; then
  echo "▸ removing venv"
  rm -rf "$VENV_DIR"
fi

echo ""
echo "✓ uninstalled."
echo "  state files preserved at: $SCRIPT_DIR/state/"
echo "  (remove manually if you want to wipe history)"
