#!/usr/bin/env python3
"""
体检 learned_rules.json —— 只读，不改任何东西。退出码非 0 = 有坏规则。

用来回答一个问题：**发音闸真的在守着吗？**

用 Python 侧的 `phonetic_gate()` 复查每条已学规则。注意 Python 闸是**故意放宽的**
（pypinyin 逐字读音集合求交，多音字全收），Swift 侧才是终审。
所以一条规则若连宽松的 Python 闸都过不了，它**必定**是坏规则，没有误报空间。
反过来不成立：过了 Python 闸不代表 Swift 会收——那由 evictNonLearnableRules() 启动时清扫。

用法：
    .venv/bin/python verify_learned_rules.py
    .venv/bin/python verify_learned_rules.py --json   # 给别的脚本吃
"""

import argparse
import importlib.util
import json
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("uh", SCRIPT_DIR / "update_hotwords.py")
uh = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(uh)

LEARNED = Path.home() / "Library/Application Support/VoiceBrother/learning/learned_rules.json"


def main():
    p = argparse.ArgumentParser(description="learned_rules.json 体检（只读）")
    p.add_argument('--json', action='store_true', help="输出 JSON 而非人读文本")
    args = p.parse_args()

    if not LEARNED.exists():
        print(f"没有 {LEARNED}——引擎还没学到任何规则。")
        return 0

    try:
        rules = json.loads(LEARNED.read_text(encoding='utf-8'))
    except (json.JSONDecodeError, OSError) as exc:
        print(f"FATAL: 读不了 learned_rules.json: {exc}")
        return 2

    if not isinstance(rules, list):
        print("FATAL: learned_rules.json 不是数组")
        return 2

    # 与 run() / Swift 的 admissionWhitelist() 同一份白名单：只认外部来源。
    # 早先这里把被测规则自己的 `to` 也灌进去，于是每条 ASCII 目标的规则都自我批准，
    # 体检对 `好了 → 我的ext` 永远报「发音闸通过」——正好漏掉它要抓的那一类。
    known = uh.known_targets()

    bad = []
    for r in rules:
        if not isinstance(r, dict):
            continue
        w, t = r.get('from', ''), r.get('to', '')
        if not w or not t:
            continue
        reason = None
        if not uh.is_replacement_candidate(w, t):
            reason = "形态闸（长度/包含/黑名单/ITN）"
        elif not uh.phonetic_gate(w, t, known):
            reason = "发音闸（连宽松的 Python 闸都不过）"
        if reason:
            bad.append({'from': w, 'to': t, 'reason': reason})

    if args.json:
        print(json.dumps({'total': len(rules), 'bad': bad}, ensure_ascii=False, indent=2))
    else:
        print(f"已学规则 {len(rules)} 条，坏规则 {len(bad)} 条\n")
        for b in bad:
            print(f"  ❌ '{b['from']}' → '{b['to']}'   {b['reason']}")
        if not bad:
            print("  ✅ 全部通过。")
        else:
            print(f"\n下次启动 app 时 evictNonLearnableRules() 应当把这 {len(bad)} 条清掉。")
            print("若重启后仍在 → 说明 Swift 侧的闸没接上，查 PhoneticGate 接入点。")

    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
