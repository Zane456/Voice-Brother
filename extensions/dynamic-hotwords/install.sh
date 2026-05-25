#!/bin/bash
# Voice Brother - 动态热词 extension 安装脚本
# 创建 venv、装依赖、安装 launchd plist（每天 04:00 跑）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"
PLIST_LABEL="com.voicebrother.dynamic-hotwords"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
LOG_DIR="$SCRIPT_DIR/state"

echo "▸ Voice Brother dynamic-hotwords installer"
echo "  script dir: $SCRIPT_DIR"

# 1. venv
if [[ ! -d "$VENV_DIR" ]]; then
  echo "▸ creating venv at $VENV_DIR"
  python3 -m venv "$VENV_DIR"
fi

echo "▸ installing python deps"
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet -r "$SCRIPT_DIR/requirements.txt"

# 2. log dir
mkdir -p "$LOG_DIR"

# 3. launchd plist
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
        <string>$VENV_DIR/bin/python</string>
        <string>$SCRIPT_DIR/update_hotwords.py</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>22</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/launchd.err.log</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
EOF

# 4. 重新加载 launchd job（如已存在）
echo "▸ (re)loading launchd job"
launchctl unload "$PLIST_DEST" 2>/dev/null || true
launchctl load "$PLIST_DEST"

echo ""
echo "✓ installed."
echo ""
echo "next steps:"
echo "  1. dry-run to verify:"
echo "     $VENV_DIR/bin/python $SCRIPT_DIR/update_hotwords.py --dry-run"
echo ""
echo "  2. real run (writes to Voice Brother UserDefaults):"
echo "     $VENV_DIR/bin/python $SCRIPT_DIR/update_hotwords.py"
echo ""
echo "  3. show current Voice Brother hotwords:"
echo "     $VENV_DIR/bin/python $SCRIPT_DIR/update_hotwords.py --show"
echo ""
echo "  scheduled: daily at 22:00 (launchd job: $PLIST_LABEL)"
echo "  logs: $LOG_DIR/update.log"
