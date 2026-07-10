#!/usr/bin/env python3
"""
锚定对齐阈值校准 —— 只读，绝不写 UserDefaults、绝不改 state、绝不调 GLM。

背景：旧的配对算法（时间窗 ±90s + 编辑距离挑最近）已实证全是乱配 ——
590 对配对里 dist==0 的有 0 对，一条 "好，你帮我合并吧" 被 5 条 ASR 记录抢着配。
新算法用 cc-prompt-log hook 记的确切提交文本做锚定，配对从「猜」变成「事实」。

本脚本回答两个问题：
  1. ANCHOR_THRESHOLD 该取多少？
  2. 新算法真的修好了吗？

**判死判活的信号是 dist0 占比。** 用户绝大多数时候原样发送 ASR 结果，
所以锚定成功的配对里 dist==0 应该占多数。旧管道是 0。若新管道仍接近 0，说明还在乱配。

**无标注的质量代理指标是拼音一致率。** 真锚定即使个别字不同，读音也几乎一致
（那正是 ASR 听错字的形态）。阈值降低到某处，拼音一致率会塌陷 —— 那就是乱配地板。

用法：
    .venv/bin/python calibrate_anchor.py                # 用 hook 数据（推荐）
    .venv/bin/python calibrate_anchor.py --proxy-jsonl  # hook 数据不够时，拿 Claude jsonl 的
                                                        # user message 当提交文本的代理
"""

import argparse
import bisect
import difflib
import importlib.util
import random
import sys
from datetime import timedelta
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("uh", SCRIPT_DIR / "update_hotwords.py")
uh = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(uh)

GRID = [0.75, 0.80, 0.85, 0.90, 0.95]


def pinyin_agreement(a: str, b: str) -> float:
    """两串的逐字读音一致率（只看汉字）。真锚定 ≈ 1.0，乱配 ≈ 0.1。"""
    ra, rb = uh._char_readings(a), uh._char_readings(b)
    if not ra or not rb:
        return 0.0
    n = min(len(ra), len(rb))
    if n == 0:
        return 0.0
    hit = sum(1 for i in range(n) if ra[i] & rb[i])
    return hit / max(len(ra), len(rb))


def anchor_pass(submissions, inject_records, threshold):
    """跑一遍锚定，返回统计 + 样本。锚定本身走生产的 `uh.anchor_segments`，
    这里只做统计，不落任何盘。绝不复制那段循环——否则报告的是另一个算法的分数。"""
    if uh._rf_fuzz is None or uh.Levenshtein is None:
        sys.exit("FATAL: 需要 rapidfuzz + Levenshtein")
    n_seg = n_anchor = n_exact = n_orphan = 0
    rates, pin_scores, samples, orphans = [], [], [], []

    for kind, seg, prompt, window, dist in uh.anchor_segments(
            submissions, inject_records, threshold):
        n_seg += 1
        inj = seg['text'].strip()
        if kind == 'orphan':
            n_orphan += 1
            if len(orphans) < 10:
                orphans.append((inj, prompt))
            continue
        if kind == 'lost':
            continue

        n_anchor += 1
        rates.append(dist / (max(len(inj), len(window)) or 1))
        if dist == 0:
            n_exact += 1
        # 短片段走的是精确匹配，dist 恒为 0，拼音一致率对它没有信息量 → 不入统计。
        # 模糊锚定则全部计入（含 dist==0），拼音一致率因此度量的是「锚对了没有」。
        if len(inj) >= uh.MIN_SEG_LEN:
            pin_scores.append(pinyin_agreement(inj, window))
            if dist != 0 and len(samples) < 200:
                samples.append((inj, window))

    return {
        'threshold': threshold,
        'segments': n_seg,
        'anchored': n_anchor,
        'unedited': n_exact,
        'unedited_pct': (n_exact / n_anchor * 100) if n_anchor else 0.0,
        'mean_edit_rate': (sum(rates) / len(rates)) if rates else 0.0,
        'pinyin_agreement': (sum(pin_scores) / len(pin_scores)) if pin_scores else 0.0,
        'orphans': n_orphan,
        'samples': samples,
        'orphan_samples': orphans,
    }


def load_proxy_submissions(days):
    """hook 数据不足时的代理：Claude jsonl 里的 user message 就是提交文本。
    时间戳同为 naive UTC，与 history.db 同构。缺点是 harness 过滤没 hook 那么干净。"""
    jsonl = uh.load_jsonl_records(days)
    return [{'ts': m['ts'], 'prompt': uh.clean_prompt(m['text'])}
            for m in jsonl['user'] if len(uh.clean_prompt(m['text'])) >= 2]


def main():
    p = argparse.ArgumentParser(description="锚定阈值校准（只读）")
    p.add_argument('--days', type=int, default=uh.LOOKBACK_DAYS)
    p.add_argument('--proxy-jsonl', action='store_true',
                   help="用 Claude jsonl 的 user message 当提交文本的代理（hook 数据不够时）")
    p.add_argument('--samples', type=int, default=15, help="打印多少对锚定样本供肉眼抽查")
    args = p.parse_args()

    inject_records = uh.load_inject_records(args.days)
    if args.proxy_jsonl:
        submissions = load_proxy_submissions(args.days)
        src = "Claude jsonl（代理）"
    else:
        submissions = uh.load_prompt_submissions(args.days)
        src = "cc-prompt-log hook"

    print(f"数据源: {src}")
    print(f"注入记录 {len(inject_records)} 条，提交记录 {len(submissions)} 条，回看 {args.days} 天\n")
    if not submissions:
        sys.exit("没有提交记录。hook 刚装的话等几天，或加 --proxy-jsonl 先看算法是否成立。")

    print("阈值    片段数  锚定数  dist0  dist0占比  平均编辑率  拼音一致率  orphan")
    print("─" * 78)
    results = {}
    for th in GRID:
        r = anchor_pass(submissions, inject_records, th)
        results[th] = r
        print(f"{th:.2f}  {r['segments']:8d}{r['anchored']:8d}{r['unedited']:7d}"
              f"{r['unedited_pct']:10.1f}%{r['mean_edit_rate']:12.3f}"
              f"{r['pinyin_agreement']:12.3f}{r['orphans']:8d}")

    print("\n判读：")
    print("  · dist0 占比应占多数（旧管道是 0.0%）。接近 0 = 仍在乱配。")
    print("  · 拼音一致率随阈值下降而塌陷的那一点，就是乱配地板。")
    print("  · orphan 数 = 交给 GLM 复核的样本量，直接决定夜间 API 花费。")

    cur = results[uh.ANCHOR_THRESHOLD]
    print(f"\n当前设定 ANCHOR_THRESHOLD={uh.ANCHOR_THRESHOLD}: "
          f"dist0 {cur['unedited_pct']:.1f}%，拼音一致率 {cur['pinyin_agreement']:.3f}，"
          f"orphan {cur['orphans']}")

    if cur['samples']:
        print(f"\n── 随机 {args.samples} 对「锚定成功但有改动」的样本（人工确认无乱配）──")
        random.seed(42)
        for inj, win in random.sample(cur['samples'], min(args.samples, len(cur['samples']))):
            sm = difflib.SequenceMatcher(None, inj, win, autojunk=False)
            spans = [(inj[i1:i2], win[j1:j2]) for tag, i1, i2, j1, j2 in sm.get_opcodes()
                     if tag == 'replace']
            print(f"\n  注入: {inj[:80]}")
            print(f"  提交: {win[:80]}")
            print(f"  拼音一致率 {pinyin_agreement(inj, win):.2f}"
                  + (f"   替换段: {spans[:4]}" if spans else ""))

    if cur['orphan_samples']:
        print(f"\n── orphan 样本（会送 GLM 复核）──")
        for inj, prompt in cur['orphan_samples'][:5]:
            print(f"\n  注入: {inj[:70]}")
            print(f"  提交: {prompt[:70]}")


if __name__ == "__main__":
    main()
