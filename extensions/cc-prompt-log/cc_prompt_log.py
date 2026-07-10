#!/usr/bin/env python3
"""
Voice Brother — Claude Code UserPromptSubmit 日志钩子

把用户每次提交的 prompt 原文 + 本地时间戳 append 到
    ~/Library/Application Support/VoiceBrother/learning/prompt_submissions.jsonl

这是自学习纠错的**信号源**：夜间脚本用它和 history.db 的注入记录做锚定对齐，
diff 出「ASR 听错的字 → 用户改对的字」。在此之前配对靠时间窗猜，全是乱配。

两条硬约束（改动前必读）：

1. 必须完全静默。UserPromptSubmit 钩子的 stdout 会被 Claude Code **注入进模型上下文**。
   任何 print / traceback 都会污染用户的 prompt。所以：不打印，异常吞掉写 hooks.log，永远 exit 0。

2. 时间戳必须是 UTC，格式 `%Y-%m-%dT%H:%M:%SZ`。app 侧 history.db 的 created_at、
   DebugLog、learning.log 全部是带 Z 的 UTC（实测 11067/11067 行都带 Z）。
   这里若写本地时间，锚定对齐会整体错开一个时区（JST 差 9 小时），
   一条都配不上，而且**不会报任何错**——整条学习管道静默失效。

本文件**只 append，从不裁剪**。日志滚动（保留 35 天）由 `extensions/dynamic-hotwords/`
的 `update_hotwords.py::prune_prompt_submissions` 在每晚挖掘末尾执行 —— 钩子必须是
几毫秒的 fire-and-forget，不能在用户按回车的路径上做文件重写。
⚠️ 因此单独安装本钩子而不装 dynamic-hotwords，日志会无限增长。
"""

import json
import os
import sys
import time

LOG = os.path.expanduser(
    "~/Library/Application Support/VoiceBrother/learning/prompt_submissions.jsonl")
ERRLOG = os.path.expanduser("~/.claude/hooks/hooks.log")


def _err(msg: str) -> None:
    try:
        with open(ERRLOG, "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} cc-prompt-log: {msg}\n")
    except OSError:
        pass


def main() -> None:
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except (json.JSONDecodeError, ValueError):
        return

    prompt = payload.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        return

    record = {
        # UTC + Z，与 history.db.created_at 完全同构。别改成本地时间。
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "prompt": prompt,
        "session_id": payload.get("session_id", ""),
        "cwd": payload.get("cwd", ""),
    }
    line = json.dumps(record, ensure_ascii=False) + "\n"

    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        # O_APPEND 让并发的多个 CC 会话各自原子追加；0600 只在首次创建时生效。
        fd = os.open(LOG, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(fd, line.encode("utf-8"))
        finally:
            os.close(fd)
        os.chmod(LOG, 0o600)
    except OSError as exc:
        _err(str(exc))


if __name__ == "__main__":
    main()
    sys.exit(0)
