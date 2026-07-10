#!/bin/bash
# Voice Brother - cc-prompt-log extension 安装脚本
#
# 把 UserPromptSubmit 钩子拷进 ~/.claude/hooks/（仓库路径含空格，直接指过去容易在
# settings.json 的 command 字符串里出事），然后提示怎么注册。
#
# 注册这一步不自动改 settings.json —— 那是用户的全局配置，脚本无声改写太粗暴。
# 安装完按提示手动加一段（或让 Claude 加）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SRC="$SCRIPT_DIR/cc_prompt_log.py"
HOOK_DIR="$HOME/.claude/hooks"
HOOK_DEST="$HOOK_DIR/cc-prompt-log.py"
LOG_FILE="$HOME/Library/Application Support/VoiceBrother/learning/prompt_submissions.jsonl"

echo "▸ Voice Brother cc-prompt-log installer"

mkdir -p "$HOOK_DIR"
cp "$HOOK_SRC" "$HOOK_DEST"
chmod 755 "$HOOK_DEST"
echo "▸ installed hook → $HOOK_DEST"

mkdir -p "$(dirname "$LOG_FILE")"
echo "▸ log dir ready → $(dirname "$LOG_FILE")"

# 静默性自检：钩子的 stdout 会被注入模型上下文，任何输出都是污染。
OUT_BYTES=$(printf '{"prompt":"__install_selftest__","session_id":"x","cwd":"/tmp"}' \
  | python3 "$HOOK_DEST" | wc -c | tr -d ' ')
if [[ "$OUT_BYTES" != "0" ]]; then
  echo "✗ FATAL: hook wrote $OUT_BYTES bytes to stdout — 会污染 Claude 上下文，中止" >&2
  exit 1
fi
echo "▸ silence check passed (stdout = 0 bytes)"

# 自检写进去的那行是测试数据，删掉，别污染训练信号。
if [[ -f "$LOG_FILE" ]]; then
  TMP=$(mktemp)
  grep -v '__install_selftest__' "$LOG_FILE" > "$TMP" || true
  mv "$TMP" "$LOG_FILE"
  chmod 600 "$LOG_FILE"
fi

cat <<'EOF'

▸ 手动完成最后一步：在 ~/.claude/settings.json 的 hooks.UserPromptSubmit
  数组里 **追加** 下面这个 entry（不要动已有的那些）：

  {
    "hooks": [
      { "type": "command", "command": "python3 ~/.claude/hooks/cc-prompt-log.py", "async": true }
    ]
  }

▸ 验证：在 Claude Code 里发一条消息，然后
  tail -1 "$HOME/Library/Application Support/VoiceBrother/learning/prompt_submissions.jsonl"

✓ done
EOF
