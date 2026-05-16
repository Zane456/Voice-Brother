#!/usr/bin/env bash
# Package Voice Brother for a friend on an Apple Silicon Mac.
#
# Produces:  dist/VoiceBrother-v<VERSION>/
#   ├── VoiceBrother.app               (arm64, ad-hoc signed, quarantine stripped)
#   ├── models/                       (0.6B ASR + VAD, pre-downloaded)
#   ├── 安装.command                   (double-click to copy app + models into place)
#   └── 使用说明.txt
# Plus a zip of the whole folder next to it.
#
# Run from repo root:  bash scripts/package-for-friend.sh

set -euo pipefail

# ---------- Config ----------
VERSION="1.0.0"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HF_CACHE="$HOME/.cache/huggingface/hub"
ASR_MODEL_DIR="models--aufklarer--Qwen3-ASR-0.6B-MLX-4bit"
VAD_MODEL_DIR="models--aufklarer--Silero-VAD-v5-MLX"

cd "$PROJECT_DIR"

echo "==> 1/6  清理旧 dist"
rm -rf dist
OUT="dist/VoiceBrother-v${VERSION}"
mkdir -p "$OUT"

# ---------- Build Release ----------
echo "==> 2/6  构建 Release 版本"
xcodebuild build \
    -project VoiceBrother.xcodeproj \
    -scheme VoiceBrother \
    -configuration Release \
    -quiet

REL_APP_SRC=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -maxdepth 5 \
    -path "*/Build/Products/Release/VoiceBrother.app" \
    -print -quit)

if [[ -z "$REL_APP_SRC" ]]; then
    echo "找不到 Release 版本的 VoiceBrother.app" >&2
    exit 1
fi
echo "    找到: $REL_APP_SRC"

# ---------- Copy + clean app ----------
echo "==> 3/6  复制 app 并剥掉 quarantine / 重新 ad-hoc 签名"
cp -R "$REL_APP_SRC" "$OUT/"
APP_DST="$OUT/VoiceBrother.app"

# Remove any quarantine xattr Xcode may have inherited (harmless if absent).
xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true

# Ad-hoc re-sign (in case modifying attrs broke the signature).
codesign --force --deep --sign - "$APP_DST" >/dev/null 2>&1 || true

# ---------- Copy model cache ----------
echo "==> 4/6  打包 0.6B ASR 模型 + VAD 模型"
mkdir -p "$OUT/models"
for dir in "$ASR_MODEL_DIR" "$VAD_MODEL_DIR"; do
    if [[ -d "$HF_CACHE/$dir" ]]; then
        echo "    复制 $dir"
        cp -R "$HF_CACHE/$dir" "$OUT/models/"
    else
        echo "    ⚠️ 缺失 $HF_CACHE/$dir  (跳过)"
    fi
done

# Stamp empty `.metadata` files for every safetensors + tokenizer/config file
# in each snapshot. The speech-swift cache-fast-path patch
# (HuggingFaceDownloader.isLocalCacheComplete) only trusts a cache that has
# these HF metadata markers — without them it falls through to hub.snapshot(),
# which tries to reach HuggingFace on every launch. Friends behind the GFW
# would hang there. The patch checks existence only, so empty stubs are enough.
echo "    生成 HuggingFace metadata 标记（跳过联网校验）"
for model_root in "$OUT/models"/*/; do
    for snap in "$model_root"snapshots/*/; do
        [[ -d "$snap" ]] || continue
        meta_dir="$snap.cache/huggingface/download"
        mkdir -p "$meta_dir"
        # Stamp every regular file present in the snapshot (safetensors, config,
        # tokenizer, merges, vocab...). Symlinks resolve to real blobs; existence
        # of the link itself is what matters here.
        for f in "$snap"*; do
            [[ -e "$f" ]] || continue
            name=$(basename "$f")
            [[ "$name" == ".cache" ]] && continue
            : > "$meta_dir/${name}.metadata"
        done
    done
done

# ---------- Installer ----------
echo "==> 5/6  生成安装脚本和使用说明"
cat > "$OUT/安装.command" <<'INSTALLER'
#!/usr/bin/env bash
# Double-click this file to install Voice Brother.
# First time: right-click -> 打开 -> 打开  (to bypass Gatekeeper on the .command).

set -e
cd "$(dirname "$0")"

echo ""
echo "============================================"
echo "  Voice Brother 一键安装"
echo "============================================"
echo ""

# 1. Copy app to /Applications
if [[ -d "/Applications/VoiceBrother.app" ]]; then
    echo "→ 检测到已有 VoiceBrother.app，覆盖中..."
    rm -rf "/Applications/VoiceBrother.app"
fi
echo "→ 正在把 VoiceBrother.app 复制到 /Applications/"
cp -R "VoiceBrother.app" "/Applications/"
xattr -dr com.apple.quarantine "/Applications/VoiceBrother.app" 2>/dev/null || true

# 2. Copy models to ~/.cache/huggingface/hub
HF_DIR="$HOME/.cache/huggingface/hub"
mkdir -p "$HF_DIR"
for d in models/*/; do
    name="$(basename "$d")"
    if [[ -d "$HF_DIR/$name" ]]; then
        echo "→ 模型 $name 已存在，跳过"
    else
        echo "→ 安装模型 $name"
        cp -R "$d" "$HF_DIR/"
    fi
done

echo ""
echo "✓ 安装完成。"
echo ""
echo "  正在打开 Voice Brother..."
echo ""
open "/Applications/VoiceBrother.app"

# Keep terminal open so user can read the output.
sleep 1
echo "（本窗口 5 秒后自动关闭）"
sleep 5
INSTALLER
chmod +x "$OUT/安装.command"

cat > "$OUT/使用说明.txt" <<'README'
Voice Brother — 使用说明
==============================

硬件要求：Apple Silicon Mac（M1/M2/M3/M4 芯片），macOS 14 或更新版本。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
安装（3 步）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. 把这整个文件夹放到任意位置（比如桌面）。

2. 右键点击「安装.command」→ 选择「打开」。
   系统会弹一个黑色警告窗，再点一次「打开」。
   （第一次必须右键打开，之后就不会再弹了。）

3. 终端会自动把 app 装到 /应用程序/，把模型放到缓存目录，
   然后自动启动 Voice Brother。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
首次启动 — 授权说明
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

应用会依次要求 3 个权限，按下面的说明点按即可：

  1. 辅助功能（用于全局快捷键监听）
     弹窗出现后会自动跳到系统设置，
     在「隐私与安全 → 辅助功能」里打开 Voice Brother 开关。

  2. 麦克风（用于录音）
     弹「好」或「允许」。

  3. 屏幕录制（用于会议纪要采集系统音频；不想用会议功能可跳过）
     授权后会看到一个「立即重启」的按钮，点一下即可 ——
     屏幕录制权限必须重启 app 才会生效，这是 macOS 的要求。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
使用
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  • 默认快捷键：按住「右 Option」键说话，松开即自动粘贴文字。
  • 可在「语音」标签页里换成其他键（⌘R / ⌥L 等）。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
AI 云端功能（可选，默认关闭）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

「语音 → AI 大模型」和「会议 → 摘要」支持接入你自己的 API Key
做文本润色/摘要。推荐用 OpenRouter（一个 key 通用多家模型）。

API Key 保存在你 Mac 的 Keychain 中，不会被上传。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
出问题？
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  • 双击 VoiceBrother.app 被 Gatekeeper 拦住 →
    右键点图标 → 打开 → 再点一次打开。

  • 首次启动模型加载慢 →
    如果模型已经预装，应该 2-3 秒就绪；
    如果看到「下载中」，说明缓存没装好，检查
    ~/.cache/huggingface/hub/ 下是否有
    models--aufklarer--Qwen3-ASR-0.6B-MLX-4bit 这个文件夹。

  • 快捷键按了没反应 →
    确认「辅助功能」权限是开着的（系统设置 → 隐私与安全）。
    某些输入法会抢右 Option 键，换成 ⌘R 试试。

README

# ---------- Zip ----------
echo "==> 6/6  打包 zip"
cd dist
ZIP_NAME="VoiceBrother-v${VERSION}.zip"
rm -f "$ZIP_NAME"
zip -rq "$ZIP_NAME" "VoiceBrother-v${VERSION}"
cd ..

TOTAL_SIZE=$(du -sh "dist/$ZIP_NAME" | awk '{print $1}')
APP_SIZE=$(du -sh "$APP_DST" | awk '{print $1}')
MODELS_SIZE=$(du -sh "$OUT/models" | awk '{print $1}')

echo ""
echo "============================================"
echo "✅ 打包完成"
echo "============================================"
echo "  ZIP 文件     : dist/$ZIP_NAME   ($TOTAL_SIZE)"
echo "  App 大小     : $APP_SIZE"
echo "  模型大小     : $MODELS_SIZE"
echo "  目录         : $OUT/"
echo ""
echo "发给朋友的方式："
echo "  AirDrop 或云盘直接发 $ZIP_NAME"
echo "  告诉朋友：解压后右键点'安装.command' → 打开"
echo ""
