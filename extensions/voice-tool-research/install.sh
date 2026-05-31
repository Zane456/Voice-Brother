#!/bin/bash
# Voice Brother - 语音工具调研 extension 安装脚本
# 装 launchd（每小时跑一次），立刻跑第一轮。共 12 轮后自动卸载。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_LABEL="com.voicebrother.voice-tool-research"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
LOG_DIR="$SCRIPT_DIR/state"

echo "▸ Voice Brother voice-tool-research installer"
echo "  script dir: $SCRIPT_DIR"

mkdir -p "$LOG_DIR"

# 检测 GLM 凭据
if ! python3 -c "
import json
with open('$HOME/Library/Application Support/VoiceBrother/credentials.json') as f:
    d = json.load(f)
assert d.get('llm.zai','').strip(), 'no llm.zai key'
" 2>/dev/null; then
  echo "✗ no GLM (z.ai) api key found — configure GLM in Voice Brother first, then re-run"
  exit 1
fi
echo "✓ GLM credentials OK"

# 写 launchd plist
echo "▸ writing launchd plist to $PLIST_DEST"
cat > "$PLIST_DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$SCRIPT_DIR/research.py</string>
    </array>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/launchd.err.log</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
EOF

# 重新加载 launchd job
echo "▸ (re)loading launchd job"
launchctl unload "$PLIST_DEST" 2>/dev/null || true
launchctl load "$PLIST_DEST"

echo ""
echo "✓ installed. launchd will fire every 3600s (1h). Script self-unloads after round 12."
echo ""
echo "running round 1 NOW to kick things off..."
python3 "$SCRIPT_DIR/research.py"

echo ""
echo "next steps:"
echo "  status:   python3 $SCRIPT_DIR/research.py --status"
echo "  reset:    python3 $SCRIPT_DIR/research.py --reset"
echo "  reports:  open $LOG_DIR/"
echo "  log:      tail -f $LOG_DIR/runs.log"
