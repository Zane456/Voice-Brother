#!/bin/bash
# Voice Brother - 语音工具调研 extension 卸载脚本
# 移除 launchd job。state/ 下的报告会保留。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_LABEL="com.voicebrother.voice-tool-research"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

if [[ -f "$PLIST_DEST" ]]; then
  echo "▸ unloading launchd job"
  launchctl unload "$PLIST_DEST" 2>/dev/null || true
  rm "$PLIST_DEST"
fi

echo "✓ uninstalled."
echo "  state files preserved at: $SCRIPT_DIR/state/"
