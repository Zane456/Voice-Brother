#!/bin/bash
# 双击此文件 → Terminal 自动打开 → 执行构建 + 重启 VoiceBrother
# 由 Claude 生成，每次改完代码双击即可

set -e
cd "$HOME/IDE project/Voice Brother"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " VoiceBrother 构建 & 重启"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "▸ 编译中..."
xcodebuild build -project VoiceBrother.xcodeproj -scheme VoiceBrother -quiet

echo "▸ 关闭旧实例..."
pkill -x "VoiceBrother" 2>/dev/null || true
sleep 0.3

echo "▸ 定位最新构建产物..."
# DerivedData 哈希在不同机器/不同 Xcode 版本下不一样，所以用通配符 + ls -t 取最新
APP_PATH=$(ls -td ~/Library/Developer/Xcode/DerivedData/VoiceBrother-*/Build/Products/Debug/VoiceBrother.app 2>/dev/null | head -1)
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "❌ 没在 DerivedData 找到 VoiceBrother.app"
    echo "   预期路径模式: ~/Library/Developer/Xcode/DerivedData/VoiceBrother-*/Build/Products/Debug/VoiceBrother.app"
    exit 1
fi

echo "▸ 启动: $APP_PATH"
open "$APP_PATH"

echo ""
echo "✅ 完成。可以关闭此窗口。"
echo ""
sleep 2
