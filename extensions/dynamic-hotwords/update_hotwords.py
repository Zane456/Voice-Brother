#!/usr/bin/env python3
"""
Voice Brother - 动态热词自动更新（独立 extension）

策略：
- 维护一个 `hotwords_manual.json` = 用户手动锁定的词（永不淘汰）
- 自动管理剩余槽位 = 用最近 N 天 Claude 回复 + ASR 历史挖掘的高缺口专名
- 总数固定 80 个上限
- 写入 com.voicebrother.app 的 hotwords UserDefaults（下次 app 启动生效）
- 每次运行写一份 changelog 到 state/update.log

完全独立运行，不依赖 Voice Brother 进程，可由 launchd 定时触发。
"""

import sqlite3
import json
import re
import os
import sys
import time
import bisect
import uuid
import functools
import difflib
import hashlib
import tempfile
import subprocess
import argparse
import urllib.request
import urllib.error
from pathlib import Path
from collections import Counter
from datetime import datetime, timedelta, timezone


def utcnow() -> datetime:
    """当前 UTC 时刻，naive（无 tzinfo）—— 与 history.db / jsonl / hook 解析出的时间戳同构。

    不用 `utcnow()`：Python 3.12 起 deprecated，未来版本会移除，
    夜间 launchd 任务会直接崩。也不用 `datetime.now()`：那是本地时间，
    拿去比 UTC 时间戳会把窗口前端砍掉一个时区（JST 9 小时），且不报错。"""
    return datetime.now(timezone.utc).replace(tzinfo=None)

try:
    import Levenshtein
except ImportError:
    Levenshtein = None  # only needed for user-edit mining; fail gracefully

try:
    from rapidfuzz import fuzz as _rf_fuzz
except ImportError:
    _rf_fuzz = None     # 锚定对齐必需；缺了就整条学习管道静默停摆

try:
    from pypinyin import pinyin as _py_pinyin, Style as _PyStyle
except ImportError:
    _py_pinyin = None   # 发音闸必需；缺了就拒绝一切中→中规则（保守方向）

APP_PROCESS_NAME = "VoiceBrother"
APP_BUNDLE_PATH = "/Applications/Voice Brother.app"

# ─── 路径配置 ───────────────────────────────────────────
HOME = Path.home()
HISTORY_DB = HOME / "Library/Application Support/VoiceBrother/history.db"
CLAUDE_PROJECTS = HOME / ".claude/projects"
APP_DOMAIN = "com.voicebrother.app"

SCRIPT_DIR = Path(__file__).resolve().parent
STATE_DIR = SCRIPT_DIR / "state"
# app 端每次转写记录的热词命中账本（LearningJournal 写入），本脚本只读、用于零命中报告
HOTWORD_HITS_FILE = HOME / "Library/Application Support/VoiceBrother/learning/hotword_hits.json"
# 热词吸附器的命中账本（LearningJournal 写入），本脚本只读、用于「吸附器有没有在干活」报告
SNAPPER_HITS_FILE = HOME / "Library/Application Support/VoiceBrother/learning/snapper_hits.json"
# cc-prompt-log hook 写入的「用户确切提交文本 + UTC 时刻」，锚定对齐的左半边
PROMPT_SUBMISSIONS_FILE = HOME / "Library/Application Support/VoiceBrother/learning/prompt_submissions.jsonl"
# 北极星指标：每天 ASR 转写 vs 用户最终输入的字符级编辑率，跨运行累积
EDIT_DIST_FILE = STATE_DIR / "edit_distance_daily.json"
MANUAL_FILE = STATE_DIR / "hotwords_manual.json"
# 用户可维护的"永不当热词"名单。纯逐字母拼读的缩写（PWM/GND/ZVS…）逐字母念
# 不会被 ASR 听错，当热词零收益还挤占 prompt 预算——列进这里，挖掘/写入都跳过。
# 大小写不敏感匹配。想恢复某个词，从本文件删掉即可。
EXCLUDE_FILE = STATE_DIR / "hotwords_exclude.json"
LAST_RUN_FILE = STATE_DIR / "last_run.json"
LOG_FILE = STATE_DIR / "update.log"

# ─── 算法配置 ───────────────────────────────────────────
HOTWORD_BUDGET = 80
LOOKBACK_DAYS = 30
MIN_CLAUDE_FREQ = 5
MAX_ASR_RECALL_RATIO = 0.3   # ASR / Claude 召回率低于此值才算"漏识别"

# ─── 锚定对齐（取代旧的「时间窗猜配对」）──────────────────
# 旧方案：在 ASR 时刻 ±90s 内挑编辑距离最小的 user message 当配对。已实证全是乱配——
# 590 对配对里 dist==0 的有 0 对，一条 "好，你帮我合并吧" 被 5 条 ASR 记录抢着配。
# 根因：一条消息由多段语音拼成 + 短消息跟谁都近 + 阈值太宽。
#
# 新方案：cc-prompt-log hook 记下**确切的提交文本和时刻**，注入片段逐个在提交文本里
# 找锚点。游标单调前进，第 i+1 段只能锚在第 i 段之后 → 多段拼接天然解决。
PROMPT_LOOKBACK_SEC = 600       # 提交时刻往前多久内的注入记录参与锚定
PROMPT_CLOCK_SKEW_SEC = 5       # 注入落库晚于提交的时钟容差
ANCHOR_THRESHOLD = 0.85         # partial_ratio 相似度下限，低于此认为用户大幅改写
MIN_SEG_LEN = 4                 # 短于此的注入片段只允许精确匹配（"OK"/"好的" 模糊匹配到处都是）
PROMPT_LOG_KEEP_DAYS = 35       # > LOOKBACK_DAYS，保证挖掘不在边界饿死
USER_EDIT_BOOST = 30            # 用户手动编辑添加的 token 在打分中的额外权重

# ─── GLM 复核通道 ────────────────────────────────────────
# 锚定失败 = 用户大幅改写，机械 diff 定位不到错字。交给 GLM 看语义。
# GLM 只负责多捞候选，闸门链一视同仁地筛（尤其发音闸，防幻觉）。
GLM_ENDPOINT = "https://api.z.ai/api/anthropic/v1/messages"
GLM_MODEL = "glm-5.2"
GLM_KEY_FILE = HOME / ".claude/secrets/glm.key"   # launchd 不读 ~/.zshrc，必须从文件读
GLM_BATCH_SIZE = 12
GLM_MAX_ITEMS_PER_NIGHT = 60
GLM_FIELD_CHARS = 400
GLM_TIMEOUT = 60
GLM_CACHE_FILE = STATE_DIR / "glm_cache.json"     # 按 sha1(raw_text) 缓存，防每晚重复计费

# 替换规则学习
MIN_RULE_OCCURRENCES = 2        # (wrong, right) 至少出现几次才被采纳——配合 is_replacement_candidate 的形态过滤已足够
MAX_LEARNED_RULES = 30          # learned 规则数量上限（manual 规则不计入）
RULE_MAX_WRONG_LEN = 20         # wrong/right 长度上限——太长大概率是误判

# ─── 通用词黑名单 + 形态过滤 ──────────────────────────────
STOPWORDS = set("""
the a an and or but if then else for in on at to of is are was were be been being
have has had do does did this that these those i you he she it we they me him her us them
my your his its our their not no yes as with by from up out so can will just what when where
how why all any some more most such only own same than too very use used using make made get
got go going see saw look looking ok okay yeah yep nope sure thanks thank one two three four
five six seven eight nine ten first second third let now next here there over under after before
also still even own each every both none nothing something anything everything someone anyone
everyone way ways thing things stuff lot lots much many few little big small large new old good
bad best worst better worse great nice fine well right wrong true false same different easy hard
work works worked working try tried trying think thought thinking know knew known known knowing
say said saying come came coming take took taken taking give gave given giving find found finding
need needs needed needing want wanted wanting like liked liking show showed shown showing put
help check checks checked checking run runs ran running fix fixed fixing read reads reading
write writes wrote written writing test tests tested testing add added adding remove removed
removing change changed changing call called calling load loaded loading save saved saving
return returns returned returning open opened opening close closed closing start started starting
stop stopped stopping pass passed passing fail failed failing build built building send sent
sending receive received receiving create created creating delete deleted deleting update updated
updating set sets setting got let lets letting via per off without within either neither nor
yet because while during through into onto upon between among across around about against
file files folder folders path paths name names line lines word words text content type types
mode modes step steps stage stages phase phases item items entry entries record records
value values key keys list lists map maps array arrays string strings number numbers integer
result results output input inputs message messages error errors info debug warning warnings
user users project projects domain domains source sources target targets script scripts session
sessions skill skills tool tools branch branches commit commits log logs report reports
example examples sample samples version versions release releases body header headers footer
api page pages link links url urls way edge case cases code codes spec specs doc docs
data state context layer level kind kinds form forms section sections part parts
real local global env config configs main src bin lib repo repos github gist
print prints printed printing parse parses parsed parsing format formats formatted
true false null none yes no maybe perhaps possibly probably likely definitely certainly
ll re ve d s t m
voice scope phase step stage status section level pending tested task round chunk block
note notes summary detail details overview reason reasons result results final cause causes
issue issues problem problems goal goals target targets task tasks step steps phase phases
done ready complete completed pending failed success warning warnings note notes summary
context option options config configs default defaults setting settings preferences setup
cc ok no go us uk or it is in on at to of be by my we he so up do am as if an
""".split())

# 中文常用口语词黑名单——与 app 端 CorrectionLearningEngine.nonLearnableTerms 同步。
# wrong 是这些词时，用户的编辑几乎都是"改写这句内容"而非"修 ASR 错字"；
# 学成全局替换会每句误触发（2026-06-08「好了→我的ext」事故，本脚本每晚把它复活）。
CJK_NON_LEARNABLE = set("""
好 好的 好了 好吧 好啊 好嘞 行 行了 可以 没问题 没事 嗯 嗯嗯 嗯哼 哦 噢 呃 啊 呀 哈 哈哈
对 对的 对对 对吧 是 是的 是吧 是啊
那 那个 这 这个 就是 就 然后 还有 而且 但是 不过 所以 因为 如果 这样 那样 这样子 那样子
现在 怎么 什么 为什么 怎么样
我 你 他 她 它 我们 你们 他们 她们 我的 你的 他的 她的 大家
""".split())
CJK_EDGE_PUNCT = '。，、！？；：…—　 \t'

# 物理量下标符号：V_o, C_b, L_b, i_b, dv_dt
SUBSCRIPT_VAR_RE = re.compile(r'^[A-Za-z]{1,3}_[a-z0-9]{1,3}$')

TOKEN_RE = re.compile(r'[A-Za-z][A-Za-z0-9._-]{1,28}[A-Za-z0-9]|[A-Za-z]{2,8}')

# Claude Code harness 注入到 user 消息里的标记，不是用户打的字。不滤掉的话
# 它们会把"编辑率"推高成假象，且 Request/interrupted/Image 等 token 会被
# 当成"用户手动添加的词"计入挖掘统计。
HARNESS_NOISE_RE = re.compile(
    r'\[Request interrupted by user[^\]]*\]|\[Image[^\]]*\]')


def is_proper_noun(token: str) -> bool:
    if not token or len(token) < 2 or len(token) > 30: return False
    if token.isdigit(): return False
    if token.lower() in STOPWORDS: return False
    if SUBSCRIPT_VAR_RE.match(token): return False
    if token.isupper() and 2 <= len(token) <= 6 and token.isalpha(): return True
    if any(c.isupper() for c in token[1:]) and any(c.islower() for c in token): return True
    if any(c in '._-' for c in token) and re.search(r'[a-zA-Z]', token): return True
    has_digit = any(c.isdigit() for c in token)
    has_alpha = any(c.isalpha() for c in token)
    if has_digit and has_alpha: return True
    if token[0].isupper() and 3 <= len(token) <= 15 and token.isalpha(): return True
    return False


def tokenize(text: str):
    text = re.sub(r'```[\s\S]*?```', ' ', text)
    text = re.sub(r'https?://\S+', ' ', text)
    return TOKEN_RE.findall(text)


# ─── 数据加载 ────────────────────────────────────────────

@functools.lru_cache(maxsize=4)
def _load_history_rows(days: int):
    """history.db 里 `days` 天内的原始行 `[(ts, text, raw_text)]`，不做空串过滤。

    `load_asr_records` 和 `load_inject_records` 都投影自它。这两个从前各开一次库、
    各写一遍同样的 SQL 和时间戳解析，然后 `created_at` 是 UTC 这件事只在其中一个
    上被修对 —— 另一个用 `datetime.now()`，窗口整体差一个时区。一个来源就不会再漂。

    ⚠️ `created_at` 是带 Z 的 UTC，窗口起点必须 `utcnow()`。"""
    if not HISTORY_DB.exists():
        log(f"FATAL: history.db not found at {HISTORY_DB}")
        sys.exit(2)
    conn = sqlite3.connect(str(HISTORY_DB))
    since = (utcnow() - timedelta(days=days)).strftime('%Y-%m-%dT%H:%M:%S')
    rows = conn.execute(
        "SELECT created_at, text, raw_text FROM transcription_history "
        "WHERE created_at > ? ORDER BY created_at ASC", (since,)).fetchall()
    conn.close()
    out = []
    for ts_str, text, raw in rows:
        try:
            ts = datetime.fromisoformat((ts_str or '').replace('Z', ''))
        except (ValueError, AttributeError):
            continue
        out.append((ts, (text or '').strip(), (raw or '').strip()))
    return tuple(out)


def load_asr_records(days: int):
    """返回 [{ts, text}]。text 优先用 raw_text（ASR 原始转写），fallback 到 text。
    喂 `mine_auto_hotwords`：热词要从 ASR 原文里挖，不能挖替换规则的产物。"""
    return [{'ts': ts, 'text': raw or text}
            for ts, text, raw in _load_history_rows(days) if raw or text]


def load_jsonl_records(days: int):
    """返回 {'user': [{ts, text}], 'assistant': [{ts, text}]}。

    ⚠️ jsonl 的 `timestamp` 是带 Z 的 UTC（`2026-07-09T11:05:54.705Z`），解析后是
    naive UTC，所以窗口起点必须 `utcnow()`。用 `datetime.now()` 会把窗口前端
    多砍掉一个时区（JST 9 小时），静默丢数据。history.db 侧同理，见 `_load_history_rows`。"""
    result = {'user': [], 'assistant': []}
    if not CLAUDE_PROJECTS.exists():
        log(f"WARN: claude projects dir not found at {CLAUDE_PROJECTS}")
        return result
    since = utcnow() - timedelta(days=days)
    for jsonl in CLAUDE_PROJECTS.rglob("*.jsonl"):
        try:
            if datetime.fromtimestamp(jsonl.stat().st_mtime) < since - timedelta(days=1):
                continue
        except OSError:
            continue
        try:
            with open(jsonl, 'r', errors='ignore') as f:
                for line in f:
                    line = line.strip()
                    if not line: continue
                    try:
                        rec = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    t = rec.get('type')
                    if t not in ('user', 'assistant'): continue
                    ts_str = rec.get('timestamp', '')
                    try:
                        ts = datetime.fromisoformat(ts_str.replace('Z',''))
                    except ValueError:
                        continue
                    if ts < since: continue
                    msg = rec.get('message', {})
                    if not isinstance(msg, dict): continue
                    content = msg.get('content', '')
                    text = ''
                    if isinstance(content, str):
                        text = content
                    elif isinstance(content, list):
                        parts = []
                        for c in content:
                            if isinstance(c, dict) and c.get('type') == 'text':
                                parts.append(c.get('text', ''))
                        text = '\n'.join(parts)
                    text = text.strip()
                    # user 消息里剥掉 harness 注入标记（[Request interrupted...]/[Image] 等）
                    if t == 'user':
                        text = HARNESS_NOISE_RE.sub(' ', text).strip()
                    if not text or len(text) < 2: continue
                    # 跳过系统注入提示——这些不是用户/AI真正写的
                    if text.startswith('<system-reminder>'): continue
                    if text.startswith('Caveat:'): continue
                    if text.startswith('<command-name>'): continue
                    result[t].append({'ts': ts, 'text': text})
        except OSError:
            continue
    result['user'].sort(key=lambda m: m['ts'])
    result['assistant'].sort(key=lambda m: m['ts'])
    return result


def extract_diff_spans(asr_text: str, user_text: str):
    """用 difflib 找 ASR ↔ user_text 之间的 replace 段，返回 [(wrong, right), ...]。
    比 token 集合 diff 精确——能识别"对应位置上的替换"，避免随机配对。"""
    sm = difflib.SequenceMatcher(None, asr_text, user_text, autojunk=False)
    out = []
    punct = ' ，。！？,.!?;；:：、…—\n\t'
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag != 'replace': continue
        wrong = asr_text[i1:i2].strip(punct)
        right = user_text[j1:j2].strip(punct)
        if wrong and right and wrong != right:
            out.append((wrong, right))
    return out


# 纯数字域字符集：中文数字侧 + ITN 输出侧。两侧都"纯"才算 ITN 规则，
# 这样 "V一"→"V1"（含字母 V）这类真正的术语规则不会被误杀。
_CN_NUM_CHARS = set("零〇一二三四五六七八九十百千万亿两点分之等于负")
_ITN_OUT_CHARS = set("0123456789.%=/+-*:")


def _is_itn_number_rule(wrong: str, right: str) -> bool:
    """wrong 全为中文数字字符、right 全为 ITN 输出字符 ⇒ 属 ITNProcessor 职责。"""
    return (all(c in _CN_NUM_CHARS for c in wrong) and
            all(c in _ITN_OUT_CHARS for c in right))


def is_replacement_candidate(wrong: str, right: str) -> bool:
    """形态闸：判断 (wrong, right) 的**形状**像不像一条术语替换规则。
    替换规则一旦生效会硬改所有匹配字符串，一条错规则比十条空规则更糟。

    注意本函数不再判断「right 是不是英文」——那条 ASCII 闸已被 `phonetic_gate()`
    取代。旧闸一刀切拒绝所有中→中规则（连「质朴→智谱」这种真同音错字也拒），
    因为当时没有拼音校验，中文硬替换太危险。现在有了发音闸，中→中可以安全放行。"""
    if not wrong or not right or wrong == right: return False
    # 常用口语词做 wrong 必然每句误触发，无条件拒绝（好了→我的ext 事故）
    if wrong.strip(CJK_EDGE_PUNCT) in CJK_NON_LEARNABLE: return False
    # 纯中文数字→阿拉伯/百分/等式（二十→20、一百→100、百分之一→1%、等于零→=0）
    # 是 ITNProcessor 的职责：它上下文感知（跳过序数"第二十"、按日期/时间/货币分场景）。
    # 硬字符串规则无上下文，会在"第二十""二十来个"里误触发，且与 ITN 重复。一律不学。
    if _is_itn_number_rule(wrong, right): return False
    if len(wrong) < 2: return False                       # 单字 wrong 误伤太多
    if len(right) < 2: return False                       # 单字 right 太通用（如"好""是"）
    if len(wrong) > RULE_MAX_WRONG_LEN: return False
    if len(right) > RULE_MAX_WRONG_LEN: return False
    if wrong in right or right in wrong: return False     # 半改动
    # right 必须含字母数字或汉字，不能全标点
    if not any(c.isalnum() or '一' <= c <= '鿿' for c in right): return False
    # right 不能含句末/分隔标点——真正的术语替换不跨句
    if any(c in '。！？；…，,.;!?\n' for c in right): return False
    # 长度比例不能太悬殊（防止短词配到长 phrase 的 difflib 噪声）
    if len(right) > 2.5 * len(wrong) or len(wrong) > 2.5 * len(right): return False
    # wrong 若是中文，限 ≤4 字短术语——完整 phrase 多半是 difflib 巧合匹配
    if sum(1 for c in wrong if '一' <= c <= '鿿') > 4: return False
    return True


# ─── 发音闸（Swift PhoneticGate 的宽松镜像）───────────────
# 权威实现在 VoiceBrother/Backend/Voice/PhoneticGate.swift。这里刻意更宽松：
# pypinyin 把「朴」读成 piao、CFStringTransform 读成 pu，两端对多音字判断不一致。
# 用 heteronym=True 取每字**读音集合**逐字求交集 → 本侧多捞，Swift 侧
# `evictNonLearnableRules()` 每次启动终审清扫。宽→严的方向是安全的。
_CJK_DIGIT_MAP = str.maketrans("〇零一二三四五六七八九", "00123456789")


def _norm_key(s: str) -> str:
    """与 Swift `PhoneticNormalize.key` 等价：小写 → 中文数字折成阿拉伯 → 只留 [a-z0-9]。"""
    s = s.translate(_CJK_DIGIT_MAP).lower()
    return ''.join(c for c in s if c.isascii() and c.isalnum())


def _is_key_safe(s: str) -> bool:
    """串里没有承载语义的字符（汉字/假名），只有 ASCII 字母数字、中文数字、标点空白。
    没这道检查的话 `啊哈GLM` 和 `GLM哦` 的规范化键都是 `glm`，会被判成 ch1 相等。"""
    for c in s.translate(_CJK_DIGIT_MAP):
        if c.isascii() and c.isalnum(): continue
        if c.isspace() or (not c.isalnum()): continue    # 标点/符号
        return False
    return True


def _all_cjk(s: str) -> bool:
    return bool(s) and all('一' <= c <= '鿿' for c in s)


def _char_readings(s: str):
    """逐字取全部读音集合。

    必须**一个字一个字**调用 `pinyin()`，不能整词调用：pypinyin 有词组库，
    整词调用会锁死读音且不展开多音字 —— `pinyin("质朴", heteronym=True)` 返回
    `[['zhi'], ['piao']]`（词库里「朴」被判成 piao），而单字 `pinyin("朴")` 才给
    `[['pu','piao','po']]`。整词模式下「质朴→智谱」会被误判成不同音。"""
    if _py_pinyin is None: return None
    out = []
    for ch in s:
        r = _readings_of(ch)
        if r is None: return None
        out.append(r)
    return out


@functools.lru_cache(maxsize=8192)
def _readings_of(ch: str):
    """单字读音集合，带缓存。整个语料只有 ~1400 个不同汉字，但 `calibrate_anchor.py`
    的拼音一致率要对整句逐字求读音 —— 无缓存时 160 万次调用耗 6.6 秒，占它总耗时 90%。"""
    r = _py_pinyin(ch, style=_PyStyle.NORMAL, heteronym=True)
    return frozenset(r[0]) if r else None


def _homophone_cjk(a: str, b: str) -> bool:
    """逐字读音集合求交集非空 ⇒ 同音。

    取交集而非比默认读音，是因为两端对多音字判断相反：pypinyin 默认把「朴」读 piao，
    Swift 的 CFStringTransform 读 pu。只比默认读音的话「质朴→智谱」在本侧被拒、
    在 Swift 侧被收，行为分裂。取交集后本侧更宽松 —— 多捞，Swift 终审，方向安全。"""
    pa, pb = _char_readings(a), _char_readings(b)
    if pa is None or pb is None or len(pa) != len(pb): return False
    return all(x & y for x, y in zip(pa, pb))


def phonetic_gate(wrong: str, right: str, known_targets: set) -> bool:
    """三通道，顺序裁决。`known_targets` 取自 `known_targets()`（只含外部来源）。"""
    w, r = wrong.strip(), right.strip()
    if not w or not r or w == r: return False

    # ch1 —— 只是空格/标点/大小写/中文数字写法不同（G L M→GLM、N八N→n8n、code x→CodeX）
    if _is_key_safe(w) and _is_key_safe(r):
        kw, kr = _norm_key(w), _norm_key(r)
        if kw and kw == kr: return True

    # ch2 —— 两侧纯汉字：同音同长才是听错字。就地裁决，不下落。
    if _all_cjk(w) and _all_cjk(r):
        return len(w) == len(r) and _homophone_cjk(w, r)

    # ch3 —— 正词是已知的英文/数字专名（cloud→Claude、克劳德→Claude）。
    # 白名单是安全性的来源：`我的ext` 不在词表里，学不进来。
    if r in known_targets:
        alnum = sum(1 for c in r if c.isascii() and c.isalnum())
        if alnum / len(r) >= 0.5: return True

    return False


def passes_gate_chain(wrong: str, right: str, raw_text: str, known_targets: set) -> bool:
    """机械候选和 GLM 候选走**同一条**闸门链，GLM 不享受任何豁免。
    频次闸 (>=MIN_RULE_OCCURRENCES) 在合并后的 rule_counts 上统一施加。"""
    if not is_replacement_candidate(wrong, right): return False
    if not phonetic_gate(wrong, right, known_targets): return False
    # raw_text 回查：规则作用在 ASR 原文上（VoiceService 用 rawText 匹配）。
    # wrong 若只存在于 polish 之后的文本里，学了也永远命中不了 = 死规则。
    if wrong not in raw_text: return False
    return True


def load_inject_records(days: int):
    """返回 [{ts, text, raw_text}]。text = 实际注入到输入框的文本（经过语气词过滤/ITN/
    替换规则/可选 LLM polish）；raw_text = ASR 原始输出。

    锚定要拿 `text` 去提交文本里找（那才是真正被键入的东西），
    规则的 raw_text 回查要拿 `raw_text`（规则作用在 ASR 原文上）。"""
    return [{'ts': ts, 'text': text, 'raw_text': raw or text}
            for ts, text, raw in _load_history_rows(days) if text]


def load_prompt_submissions(days: int):
    """返回 [{ts, prompt}]，按时间升序。由 cc-prompt-log hook 写入。

    ⚠️ 时区：hook 写的是 UTC（带 Z），`history.db.created_at` 也是 UTC（带 Z），
    `load_jsonl_records` 同样把 Z 剥掉当 naive UTC。三者一致，锚定才对得上。
    任一侧改成本地时间都会让锚定整体错开一个时区且不报错。

    文件不存在 = hook 还没装（或刚装还没数据）→ 返回空，规则学习静默停摆，
    热词挖掘不受影响。"""
    if not PROMPT_SUBMISSIONS_FILE.exists():
        log(f"WARN: {PROMPT_SUBMISSIONS_FILE.name} 不存在——cc-prompt-log hook 未安装？跳过规则学习")
        return []
    since = utcnow() - timedelta(days=days)
    out = []
    with open(PROMPT_SUBMISSIONS_FILE, 'r', errors='ignore') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            try:
                ts = datetime.fromisoformat(rec['ts'].replace('Z', ''))
            except (ValueError, KeyError, AttributeError):
                continue
            if ts < since: continue
            prompt = clean_prompt(rec.get('prompt', ''))
            if len(prompt) >= 2:
                out.append({'ts': ts, 'prompt': prompt})
    out.sort(key=lambda m: m['ts'])
    return out


def clean_prompt(text: str) -> str:
    """剥掉 harness 注入的标记，只留用户真正打进去的字。"""
    if not text: return ''
    text = HARNESS_NOISE_RE.sub(' ', text)
    for marker in ('<system-reminder>', '<command-name>', '<local-command-caveat>'):
        idx = text.find(marker)
        if idx >= 0:
            text = text[:idx]
    return text.strip()


def prune_prompt_submissions(keep_days: int = PROMPT_LOG_KEEP_DAYS):
    """滚动清理。放在挖掘阶段（不是 hook 里——hook 必须是几毫秒的 fire-and-forget）。
    原子替换；清理窗口 > LOOKBACK_DAYS，保证挖掘不在边界饿死。"""
    if not PROMPT_SUBMISSIONS_FILE.exists(): return
    cutoff = utcnow() - timedelta(days=keep_days)   # hook 写的是 UTC
    kept, dropped = [], 0
    with open(PROMPT_SUBMISSIONS_FILE, 'r', errors='ignore') as f:
        for line in f:
            try:
                ts = datetime.fromisoformat(json.loads(line)['ts'].replace('Z', ''))
            except (json.JSONDecodeError, ValueError, KeyError, AttributeError):
                continue
            if ts >= cutoff: kept.append(line)
            else: dropped += 1
    if not dropped: return
    fd, tmp = tempfile.mkstemp(dir=str(PROMPT_SUBMISSIONS_FILE.parent))
    with os.fdopen(fd, 'w') as f:
        f.writelines(kept)
    os.chmod(tmp, 0o600)
    os.replace(tmp, PROMPT_SUBMISSIONS_FILE)
    log(f"pruned {dropped} prompt submissions older than {keep_days}d ({len(kept)} kept)")


# ─── 锚定对齐 ────────────────────────────────────────────

def attribute_injects_to_submissions(submissions, inject_records):
    """把每条注入记录归属到**唯一一条**提交：时间上紧随其后、且间隔 ≤ 10 分钟的那条。

    ❗不能反过来「对每条提交扫窗口内的所有注入」——相邻提交的 10 分钟窗口互相重叠，
    同一条注入会被 6.8 条提交重复锚定（实测 11053 条注入被处理成 74900 个片段）。
    后果：同一 (wrong,right) 被重复计数，频次闸 `>=2` 形同虚设；GLM 队列爆炸到 6 万条。

    因果方向也决定了归属方向：语音先注入，用户随后（可能再说几段、再手打）才提交。
    所以一条注入属于它之后最近的那次提交。

    返回 {submission_index: [inject, ...]}，组内保持时间升序。
    """
    groups = {}
    sub_ts = [s['ts'] for s in submissions]
    for seg in inject_records:
        i = bisect.bisect_left(sub_ts, seg['ts'] - timedelta(seconds=PROMPT_CLOCK_SKEW_SEC))
        if i >= len(submissions): continue
        if (submissions[i]['ts'] - seg['ts']).total_seconds() > PROMPT_LOOKBACK_SEC: continue
        groups.setdefault(i, []).append(seg)
    return groups


def anchor_segments(submissions, inject_records, threshold=ANCHOR_THRESHOLD):
    """逐段锚定，yield `(kind, seg, prompt, window, dist)`。**唯一的锚定实现。**

    `kind` ∈ {'anchored', 'orphan', 'lost'}：
      · anchored —— 定位到区间，`window` 是提交文本里对应的那一段，`dist` 是编辑距离
      · orphan   —— 定位不到（用户大幅改写），`window`/`dist` 为 None，交 GLM 看语义
      · lost     —— 短片段精确匹配失败，既不锚定也不送 GLM（模糊匹配它会打乱游标）

    两级结构：
    1. `attribute_injects_to_submissions` 先做**唯一归属**，一条注入只属于一条提交。
    2. 组内用**单调游标**：第 i 段只在 `prompt[cursor:]` 里搜，锚定成功后 cursor 跳到区间末尾。
       于是
         · 一条消息由多段语音拼成 → 每段各自锚到自己的区间，物理上不可能抢
         · 段与段之间用户手打的内容 → 落在两个区间的空隙里，天然被跳过
       区间掩码（把已用字符替换成哨兵）是错的：partial_ratio 会跨过哨兵继续匹配。

    `calibrate_anchor.py` 和 `mine_anchored_pairs` 共用它。校准脚本存在的意义就是给
    生产算法出体检报告——各写一份锚定循环，报告出的是另一个算法的分数。
    """
    if _rf_fuzz is None or Levenshtein is None:
        log("WARN: rapidfuzz/Levenshtein 缺失，跳过锚定对齐")
        return
    if not submissions or not inject_records:
        return

    groups = attribute_injects_to_submissions(submissions, inject_records)
    for sub_idx, segs in groups.items():
        prompt = submissions[sub_idx]['prompt']
        cursor = 0
        for seg in segs:
            inj = seg['text'].strip()
            if not inj: continue

            # 短片段守卫：「OK」「好的」模糊匹配到处都是，会打乱游标。只认精确匹配。
            if len(inj) < MIN_SEG_LEN:
                idx = prompt.find(inj, cursor)
                if idx < 0:
                    yield 'lost', seg, prompt, None, None
                    continue
                cursor = idx + len(inj)
                yield 'anchored', seg, prompt, inj, 0
                continue

            hay = prompt[cursor:]
            al = (_rf_fuzz.partial_ratio_alignment(inj, hay, score_cutoff=threshold * 100)
                  if hay else None)
            if al is None:
                # 用户大幅改写 → 机械 diff 定位不到错字，交 GLM 看语义
                yield 'orphan', seg, prompt, None, None
                continue

            window = prompt[cursor + al.dest_start:cursor + al.dest_end]
            cursor += al.dest_end
            yield 'anchored', seg, prompt, window, Levenshtein.distance(inj, window)


def mine_anchored_pairs(submissions, inject_records, known_targets):
    """锚定每条注入片段，再从锚定窗口 diff 出 (wrong, right)。

    取代旧的 `mine_user_edits` + `mine_replacement_rules`（时间窗猜配对，已证实全乱配）。
    锚定本身在 `anchor_segments`，这里只做记账和闸门。

    返回 (user_added, rule_counts, rule_ctx, pair_stats, glm_queue)，
    前四个的形状与旧函数一致，下游 `mine_auto_hotwords` / `save_edit_distance_daily` 不用改。
    """
    user_added, rule_counts, rule_ctx = Counter(), Counter(), {}
    pair_stats, glm_queue = [], []
    n_seg = n_anchor = n_exact = n_orphan = 0

    for kind, seg, prompt, window, dist in anchor_segments(submissions, inject_records):
        n_seg += 1
        day = seg['ts'].strftime('%Y-%m-%d')

        if kind == 'orphan':
            glm_queue.append({'raw_text': seg['raw_text'], 'prompt': prompt, 'date': day})
            n_orphan += 1
            continue
        if kind == 'lost':
            continue

        inj = seg['text'].strip()
        n_anchor += 1
        if dist == 0: n_exact += 1
        pair_stats.append({'date': day, 'dist': dist, 'len': max(len(inj), len(window))})
        if dist == 0: continue      # 用户原样发送，没有可学的东西

        for tok in set(tokenize(window)) - set(tokenize(inj)):
            user_added[tok] += 1
        for wrong, right in extract_diff_spans(inj, window):
            if not passes_gate_chain(wrong, right, seg['raw_text'], known_targets): continue
            rule_counts[(wrong, right)] += 1
            rule_ctx.setdefault((wrong, right), seg['raw_text'][:80])

    pct = (n_exact / n_anchor * 100) if n_anchor else 0
    log(f"anchored pairing: {n_seg} segments → {n_anchor} anchored "
        f"({n_exact} unedited, {pct:.1f}%), {n_orphan} orphans → GLM, "
        f"{len(rule_counts)} rule candidates")
    return user_added, rule_counts, rule_ctx, pair_stats, glm_queue


# ─── GLM 复核通道 ────────────────────────────────────────

GLM_PROMPT_HEADER = """你是语音识别纠错助手。下面每一项包含两段中文文本：
- asr: 语音识别系统听写出的原始文本，可能有"听错的字"（同音/音近但字写错）
- final: 用户最终真正想输入的文本（已经改好）

你的唯一任务：找出 asr 中【被听错的字/词】——发音相同或相近、但字写错的地方——
给出 (wrong, right)。wrong 是 asr 里的错字串，right 是 final 里对应的正确字串。

严格规则：
1. 只挑"同音或音近听错"的字，例如「张争→张诤」「质朴→智谱」「机气→机器」。
2. 绝不要挑：用户改写说法、增删内容、调整语序、增减语气词、标点差异、口语转书面。
   这些是用户的编辑，不是识别错误。
3. wrong 必须是 asr 里【逐字原样出现】的连续子串，不得改写、不得跨标点拼接。
4. wrong 与 right 长度应相等或极接近（同音错字通常等长）。
5. 该项没有任何"听错的字"就返回空数组。宁可漏报，绝不错报。

只输出 JSON 数组，不要任何解释、不要 markdown 代码块：
[{"index": 0, "pairs": [{"wrong": "张争", "right": "张诤"}]}, {"index": 1, "pairs": []}]

待处理项：
"""


def _read_glm_key():
    """launchd 不读 ~/.zshrc，环境变量在夜间任务里不可靠 → 优先读文件。"""
    try:
        key = GLM_KEY_FILE.read_text().strip()
        if key: return key
    except OSError:
        pass
    return os.environ.get("GLM_API_KEY", "").strip()


def _call_glm(prompt_text: str, timeout: int = GLM_TIMEOUT):
    key = _read_glm_key()
    if not key:
        raise RuntimeError("no GLM key")
    body = json.dumps({
        "model": GLM_MODEL,
        "max_tokens": 2048,
        "messages": [{"role": "user", "content": prompt_text}],
    }).encode()
    req = urllib.request.Request(GLM_ENDPOINT, data=body, headers={
        "Content-Type": "application/json",
        "x-api-key": key,
        "anthropic-version": "2023-06-01",
    })
    last = None
    for attempt in range(2):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                payload = json.loads(resp.read().decode())
            for block in payload.get("content", []):
                if isinstance(block, dict) and block.get("type") == "text":
                    return block["text"]
            raise RuntimeError("no text block in GLM response")
        except (urllib.error.URLError, OSError, ValueError, KeyError) as exc:
            last = exc
            if attempt == 0: time.sleep(1.5)
    raise RuntimeError(f"GLM call failed: {last}")


def _parse_glm_json(text: str):
    text = text.strip()
    if text.startswith("```"):
        text = re.sub(r'^```[a-z]*\n?', '', text)
        text = re.sub(r'\n?```$', '', text)
    return json.loads(text)


def _load_glm_cache():
    try:
        return json.loads(GLM_CACHE_FILE.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def _save_glm_cache(cache: dict):
    try:
        GLM_CACHE_FILE.write_text(json.dumps(cache, ensure_ascii=False, indent=1))
    except OSError as exc:
        log(f"WARN: 写 glm_cache 失败: {exc}")


def review_orphans_with_glm(glm_queue, known_targets, rule_counts, rule_ctx):
    """锚定失败的样本交 GLM 看语义，挑出「听错的字」候选。

    ❗GLM 的输出不享受任何豁免——照走 `passes_gate_chain`（尤其发音闸，防幻觉），
    频次闸也和机械候选合并后统一施加，单次命中无法自我晋升成规则。

    ❗缓存按 sha1(raw_text)。脚本每晚重扫 30 天窗口，没有缓存就会对同一批
    失败样本无限重复计费。
    """
    if not glm_queue: return 0
    cache = _load_glm_cache()
    pending = []
    for item in glm_queue:
        h = hashlib.sha1(item['raw_text'].encode()).hexdigest()
        if h in cache:
            for p in cache[h]:
                _absorb_glm_pair(p, item, known_targets, rule_counts, rule_ctx)
        else:
            item['_hash'] = h
            pending.append(item)

    # 同一条 raw_text 可能出现在多条提交里，去重后再发
    seen, uniq = set(), []
    for item in pending:
        if item['_hash'] in seen: continue
        seen.add(item['_hash'])
        uniq.append(item)
    uniq = uniq[:GLM_MAX_ITEMS_PER_NIGHT]
    if len(pending) > len(uniq):
        log(f"GLM: {len(pending)} orphans → {len(uniq)} unique, capped at {GLM_MAX_ITEMS_PER_NIGHT}/night")

    absorbed = 0
    for i in range(0, len(uniq), GLM_BATCH_SIZE):
        batch = uniq[i:i + GLM_BATCH_SIZE]
        lines = []
        for j, item in enumerate(batch):
            lines.append(f'[{j}] asr: "{item["raw_text"][:GLM_FIELD_CHARS]}"')
            lines.append(f'    final: "{item["prompt"][:GLM_FIELD_CHARS]}"')
        try:
            raw = _call_glm(GLM_PROMPT_HEADER + "\n".join(lines))
            results = _parse_glm_json(raw)
        except (RuntimeError, json.JSONDecodeError) as exc:
            log(f"WARN: GLM batch {i // GLM_BATCH_SIZE} 失败，跳过: {exc}")
            continue
        if not isinstance(results, list):
            log("WARN: GLM 返回不是数组，跳过该批")
            continue
        for entry in results:
            if not isinstance(entry, dict): continue
            idx = entry.get("index")
            if not isinstance(idx, int) or not (0 <= idx < len(batch)): continue
            item = batch[idx]
            pairs = [p for p in entry.get("pairs", [])
                     if isinstance(p, dict) and p.get("wrong") and p.get("right")]
            cache[item['_hash']] = pairs
            for p in pairs:
                if _absorb_glm_pair(p, item, known_targets, rule_counts, rule_ctx):
                    absorbed += 1
        # 该批里 GLM 没提到的项也要写空缓存，否则明晚重发
        for item in batch:
            cache.setdefault(item['_hash'], [])

    _save_glm_cache(cache)
    log(f"GLM review: {len(uniq)} items sent, {absorbed} pairs passed the gate chain")
    return absorbed


def _absorb_glm_pair(pair, item, known_targets, rule_counts, rule_ctx) -> bool:
    wrong, right = str(pair.get("wrong", "")), str(pair.get("right", ""))
    if not passes_gate_chain(wrong, right, item['raw_text'], known_targets):
        return False
    rule_counts[(wrong, right)] += 1
    rule_ctx.setdefault((wrong, right), item['raw_text'][:80])
    return True


def archive_v1_edit_distance():
    """一次性归档 v1 指标。旧文件里的 `mean_edit_rate≈0.54` 测的不是编辑率，是
    **乱配率**（旧配对算法把无关的 ASR 记录和 user message 配到一起）。铁证是
    `unedited: 0`——4066 对配对没有一对是完全相同的。两代数据不可比，不得合并。"""
    v1 = EDIT_DIST_FILE.with_suffix(EDIT_DIST_FILE.suffix + '.v1-invalid')
    if EDIT_DIST_FILE.exists() and not v1.exists():
        os.rename(EDIT_DIST_FILE, v1)
        log(f"archived v1 metric → {v1.name}（旧数据测的是乱配率，不可比）")


def save_edit_distance_daily(pair_stats):
    """北极星指标落盘：按天聚合「注入文本 ↔ 锚定窗口」的归一化编辑率。
    只统计**锚定成功**的配对，所以 `unedited`（dist==0）恢复了物理意义——
    用户绝大多数时候原样发送 ASR 结果，它该占多数。若又变成 0，说明锚定回归了。"""
    if not pair_stats: return
    by_day = {}
    for s in pair_stats:
        by_day.setdefault(s['date'], []).append(s)
    existing = {}
    if EDIT_DIST_FILE.exists():
        try:
            existing = json.loads(EDIT_DIST_FILE.read_text())
        except (json.JSONDecodeError, OSError):
            log("WARN: edit_distance_daily.json unreadable, rebuilding")
    for day, items in by_day.items():
        rates = [i['dist'] / i['len'] for i in items]
        existing[day] = {
            'pairs': len(items),
            'unedited': sum(1 for i in items if i['dist'] == 0),
            'mean_edit_rate': round(sum(rates) / len(rates), 4),
        }
    ensure_state_dir()
    EDIT_DIST_FILE.write_text(
        json.dumps(dict(sorted(existing.items())), ensure_ascii=False, indent=1))
    recent = sorted(existing.items())[-7:]
    trend = ', '.join(f"{d[5:]}={v['mean_edit_rate']:.1%}({v['pairs']}对)" for d, v in recent)
    log(f"edit-rate daily (北极星指标, last 7d): {trend}")


def report_hotword_hits(final_words):
    """报告当前热词的累计实测命中（app 端 hotword_hits.json，转写文本命中即计数）。
    只报告不淘汰 —— 淘汰决策留给人（新加入的词还没机会命中，不能光看零命中就杀）。"""
    if not HOTWORD_HITS_FILE.exists():
        log("hotword hits: app 端还没生成 hotword_hits.json（新账本，等转写积累）")
        return
    try:
        hits = json.loads(HOTWORD_HITS_FILE.read_text())
    except (json.JSONDecodeError, OSError):
        log("WARN: hotword_hits.json unreadable")
        return
    hits_lc = {k.lower(): v for k, v in hits.items()}
    zero = [w for w in final_words if w.lower() not in hits_lc]
    top = sorted(((w, hits_lc[w.lower()].get('hits', 0)) for w in final_words
                  if w.lower() in hits_lc), key=lambda x: -x[1])[:10]
    log(f"hotword hits: {len(final_words) - len(zero)}/{len(final_words)} 个热词在转写中出现过"
        f"；top: {', '.join(f'{w}({c})' for w, c in top)}")
    if zero:
        log(f"  zero-hit ({len(zero)}): {', '.join(zero[:30])}{' ...' if len(zero) > 30 else ''}")


def report_snapper_hits():
    """报告热词吸附器的累计命中（app 端 snapper_hits.json）。

    `CorrectionLearningEngine.noteSnapperHits` 写这个账本，注释说「让夜间报告分辨出
    一个真在干活的吸附器和一个从不触发的吸附器」——那条注释以前是空头支票，没人读它。
    零命中 = 吸附器白跑，该查热词表里有没有它能还原的目标词。"""
    if not SNAPPER_HITS_FILE.exists():
        log("snapper hits: 还没生成 snapper_hits.json（吸附器尚未命中过）")
        return
    try:
        hits = json.loads(SNAPPER_HITS_FILE.read_text())
    except (json.JSONDecodeError, OSError):
        log("WARN: snapper_hits.json unreadable")
        return
    top = sorted(((w, v.get('hits', 0)) for w, v in hits.items()), key=lambda x: -x[1])[:10]
    total = sum(v.get('hits', 0) for v in hits.values())
    log(f"snapper hits: {total} 次吸附，覆盖 {len(hits)} 个目标词"
        f"；top: {', '.join(f'{w}({c})' for w, c in top)}")


# ─── UserDefaults 读写 ──────────────────────────────────

def read_current_hotwords() -> list:
    """从 com.voicebrother.app 读当前 hotwords。返回 list of str。"""
    try:
        result = subprocess.run(
            ['defaults', 'export', APP_DOMAIN, '-'],
            capture_output=True, check=True)
        import plistlib
        plist = plistlib.loads(result.stdout)
        hw_data = plist.get('hotwords')
        if hw_data is None: return []
        if isinstance(hw_data, bytes):
            return json.loads(hw_data.decode('utf-8'))
        if isinstance(hw_data, str):
            return json.loads(hw_data)
        if isinstance(hw_data, list):
            return hw_data
    except subprocess.CalledProcessError as e:
        log(f"WARN: defaults export failed: {e}")
    except Exception as e:
        log(f"WARN: parse hotwords failed: {e}")
    return []


def is_app_running() -> bool:
    """Voice Brother 是否在跑"""
    try:
        subprocess.run(['pgrep', '-x', APP_PROCESS_NAME],
                       check=True, capture_output=True)
        return True
    except subprocess.CalledProcessError:
        return False


def gracefully_stop_app(timeout: int = 10) -> bool:
    """SIGTERM 让 Voice Brother 正常退出（触发 willTerminate → save 当前内存中的配置）。
    必须等它完全退出后才能写 UserDefaults，否则它的 save() 会把旧的 hotwords 覆写回去。"""
    if not is_app_running():
        return False
    log(f"stopping {APP_PROCESS_NAME} (SIGTERM) to release UserDefaults lock")
    subprocess.run(['pkill', '-x', APP_PROCESS_NAME], capture_output=True)
    for i in range(timeout):
        if not is_app_running():
            log(f"  app exited after {i+1}s")
            return True
        time.sleep(1)
    log(f"WARN: app still running after {timeout}s, proceeding anyway")
    return True


def restart_app():
    """启动 Voice Brother"""
    log(f"restarting {APP_PROCESS_NAME}")
    subprocess.run(['open', APP_BUNDLE_PATH], capture_output=True)


def read_current_replacements() -> list:
    """从 com.voicebrother.app 读当前 replacements 数组。"""
    try:
        result = subprocess.run(['defaults', 'export', APP_DOMAIN, '-'],
                                capture_output=True, check=True)
        import plistlib
        plist = plistlib.loads(result.stdout)
        data = plist.get('replacements')
        if isinstance(data, bytes):
            return json.loads(data.decode('utf-8'))
        if isinstance(data, list):
            return data
    except (subprocess.CalledProcessError, Exception):
        pass
    return []


def known_targets() -> set:
    """发音闸 ch3 的准入白名单：app 当前热词 ∪ **手动**规则的 `to`。

    Swift 侧 `CorrectionLearningEngine.admissionWhitelist()` 的镜像，语义必须一致：
    **只认外部来源，已学规则的 `to` 一律排除**。否则 ch3 退化成「这条规则的目标词
    在词表里，因为这条规则在」——每条 ASCII 目标的坏规则都自我批准，
    `好了 → 我的ext` 这类事故就再也清不掉（`我的ext` 有 3/5 是 ASCII 字母）。

    唯一定义，`run()` 和 `verify_learned_rules.py` 共用。分头拼一份就会漂移。"""
    targets = set(read_current_hotwords())
    targets |= {r['to'] for r in read_current_replacements()
                if r.get('source') != 'learned' and r.get('to')}
    targets.discard('')
    return targets


def write_replacements(rules: list) -> bool:
    """把 replacements 数组以 JSON-encoded NSData 形式写回 UserDefaults。"""
    payload = json.dumps(rules, ensure_ascii=False).encode('utf-8')
    try:
        subprocess.run(
            ['defaults', 'write', APP_DOMAIN, 'replacements', '-data', payload.hex()],
            check=True, capture_output=True)
        return True
    except subprocess.CalledProcessError as e:
        log(f"FATAL: replacements write failed: {e.stderr.decode(errors='ignore')}")
        return False


def build_learned_rule(wrong: str, right: str) -> dict:
    return {
        'id': str(uuid.uuid4()).upper(),
        'from': wrong,
        'to': right,
        'source': 'learned',
    }


def write_hotwords(hotwords: list) -> bool:
    """把 hotwords 数组以 JSON-encoded NSData 形式写回 UserDefaults。

    Voice Brother 的 AppConfig 把 hotwords 编码为 Data（不是 plist Array）：
        if let hwData = try? JSONEncoder().encode(hotwords) {
            defaults.set(hwData, forKey: "hotwords")
        }
    所以必须用 -data 写入 hex-encoded JSON 字节，否则 app 那边解码失败。
    """
    payload = json.dumps(hotwords, ensure_ascii=False).encode('utf-8')
    hex_str = payload.hex()
    try:
        subprocess.run(
            ['defaults', 'write', APP_DOMAIN, 'hotwords', '-data', hex_str],
            check=True, capture_output=True)
        return True
    except subprocess.CalledProcessError as e:
        log(f"FATAL: defaults write failed: {e.stderr.decode(errors='ignore')}")
        return False


# ─── 核心算法 ───────────────────────────────────────────

def mine_auto_hotwords(asr_records, assistant_records, user_added, manual_set, budget, exclude_lc=frozenset()):
    """综合 Claude 回复频次 + ASR 召回缺口 + 用户手动编辑添加的 token，挖出 budget 个候选热词。

    打分：
      base = (1 - recall) * sqrt(claude_freq)
      score = base + USER_EDIT_BOOST * sqrt(user_added_count)
    user 手动加过的 token 会显著前置 —— 用户自己改的就是 ground truth。"""
    asr_freq = Counter()
    for r in asr_records:
        for tok in tokenize(r['text']):
            asr_freq[tok] += 1
    claude_freq = Counter()
    for r in assistant_records:
        for tok in tokenize(r['text']):
            claude_freq[tok] += 1
    # 大小写规范化：以 Claude 回复里的首次写法为准
    canonical = {}
    merged_claude = Counter()
    merged_asr = Counter()
    merged_user_added = Counter()
    for tok, cnt in claude_freq.most_common():
        key = tok.lower()
        if key not in canonical:
            canonical[key] = tok
        merged_claude[canonical[key]] += cnt
    for tok, cnt in asr_freq.items():
        target = canonical.get(tok.lower(), tok)
        merged_asr[target] += cnt
    for tok, cnt in user_added.items():
        # 用户加的 token 可能在 Claude 回复里也出现过 —— 用同一个 canonical
        # 没出现过的就保留用户原始拼写
        target = canonical.get(tok.lower(), tok)
        merged_user_added[target] += cnt
        # 让用户加过但 Claude 没说过的 token 也能进候选池
        if target not in merged_claude:
            merged_claude[target] = 0
    manual_lc = {w.strip().lower() for w in manual_set if w.strip()}
    out = []
    for tok, c_freq in merged_claude.most_common(2000):
        if not is_proper_noun(tok): continue
        if tok.lower() in manual_lc: continue
        if tok.lower() in exclude_lc: continue   # 纯拼读缩写永不当热词
        u_added = merged_user_added.get(tok, 0)
        # 入围条件：Claude 频次够高 OR 用户至少手动加过 1 次
        if c_freq < MIN_CLAUDE_FREQ and u_added < 1: continue
        a_freq = merged_asr.get(tok, 0)
        recall = a_freq / c_freq if c_freq else 0.0
        # Claude 高频且 ASR 召回也高的 —— 除非用户手动加过，否则跳过
        if recall >= MAX_ASR_RECALL_RATIO and u_added < 1: continue
        base = (1 - recall) * (c_freq ** 0.5) if c_freq else 0
        boost = USER_EDIT_BOOST * (u_added ** 0.5)
        score = base + boost
        out.append({
            'token': tok,
            'claude': c_freq,
            'asr': a_freq,
            'user_added': u_added,
            'score': round(score, 2),
        })
    out.sort(key=lambda x: -x['score'])
    return out[:budget]


# ─── 状态管理 ───────────────────────────────────────────

def ensure_state_dir():
    STATE_DIR.mkdir(parents=True, exist_ok=True)


def load_manual() -> list:
    """读手动锁定集。首次运行时从当前 UserDefaults 抓 snapshot 作为初始值。"""
    ensure_state_dir()
    if not MANUAL_FILE.exists():
        snapshot = read_current_hotwords()
        if snapshot:
            log(f"INIT: snapshot {len(snapshot)} existing hotwords as manual-locked")
        else:
            log("INIT: no existing hotwords found, manual set starts empty")
        with open(MANUAL_FILE, 'w') as f:
            json.dump(snapshot, f, ensure_ascii=False, indent=2)
        return snapshot
    with open(MANUAL_FILE) as f:
        try:
            return json.load(f)
        except json.JSONDecodeError:
            log(f"WARN: manual file corrupted, treating as empty")
            return []


def load_exclude() -> set:
    """读"永不当热词"名单，返回小写集合（大小写不敏感匹配）。文件不存在＝空集。"""
    if not EXCLUDE_FILE.exists():
        return set()
    try:
        with open(EXCLUDE_FILE) as f:
            return {w.strip().lower() for w in json.load(f) if str(w).strip()}
    except (json.JSONDecodeError, OSError):
        log("WARN: exclude file corrupted, treating as empty")
        return set()


def save_last_run(manual, auto, final):
    ensure_state_dir()
    snapshot = {
        'timestamp': datetime.now().isoformat(timespec='seconds'),
        'lookback_days': LOOKBACK_DAYS,
        'budget': HOTWORD_BUDGET,
        'manual_count': len(manual),
        'auto_count': len(auto),
        'final_count': len(final),
        'manual': manual,
        'auto': [a['token'] for a in auto],
        'auto_with_scores': auto,
        'final': final,
    }
    with open(LAST_RUN_FILE, 'w') as f:
        json.dump(snapshot, f, ensure_ascii=False, indent=2)


def diff_with_previous(new_list: list) -> tuple:
    """对比上次运行的 final，返回 (added, removed)"""
    if not LAST_RUN_FILE.exists(): return [], []
    try:
        with open(LAST_RUN_FILE) as f:
            prev = json.load(f).get('final', [])
    except (json.JSONDecodeError, OSError):
        return [], []
    prev_set = {w.lower() for w in prev}
    new_set = {w.lower() for w in new_list}
    added = [w for w in new_list if w.lower() not in prev_set]
    removed = [w for w in prev if w.lower() not in new_set]
    return added, removed


# ─── 日志 ────────────────────────────────────────────────

def log(msg: str):
    ensure_state_dir()
    ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    line = f"[{ts}] {msg}"
    print(line)
    try:
        with open(LOG_FILE, 'a') as f:
            f.write(line + '\n')
    except OSError:
        pass


# ─── 主流程 ──────────────────────────────────────────────

def run(dry_run: bool = False, no_restart: bool = False, no_glm: bool = False):
    log("=" * 60)
    log(f"START dry_run={dry_run} no_restart={no_restart} no_glm={no_glm} lookback={LOOKBACK_DAYS}d budget={HOTWORD_BUDGET}")

    exclude_lc = load_exclude()
    manual = [w for w in load_manual() if w.strip().lower() not in exclude_lc]
    if exclude_lc:
        log(f"exclude list: {len(exclude_lc)} words (纯拼读缩写永不当热词)")
    log(f"manual-locked words: {len(manual)}")

    auto_budget = HOTWORD_BUDGET - len(manual)
    if auto_budget <= 0:
        log(f"WARN: manual set ({len(manual)}) already fills budget ({HOTWORD_BUDGET}). No auto words added.")
        auto = []
        rule_counts, rule_ctx = Counter(), {}
        asr_records = []
        jsonl = {'user': [], 'assistant': []}
    else:
        asr_records = load_asr_records(LOOKBACK_DAYS)
        jsonl = load_jsonl_records(LOOKBACK_DAYS)
        log(f"loaded {len(asr_records)} ASR records, {len(jsonl['user'])} user msgs, {len(jsonl['assistant'])} assistant msgs")

        # ── 规则学习：hook 记录的确切提交文本 × 注入记录，锚定对齐 ──
        inject_records = load_inject_records(LOOKBACK_DAYS)
        submissions = load_prompt_submissions(LOOKBACK_DAYS)
        log(f"loaded {len(inject_records)} inject records, {len(submissions)} prompt submissions")
        targets = known_targets()   # 发音闸 ch3 的白名单，只含外部来源
        user_added, rule_counts, rule_ctx, pair_stats, glm_queue = mine_anchored_pairs(
            submissions, inject_records, targets)
        archive_v1_edit_distance()
        save_edit_distance_daily(pair_stats)
        if glm_queue and not no_glm:
            review_orphans_with_glm(glm_queue, targets, rule_counts, rule_ctx)
        elif glm_queue:
            log(f"GLM review skipped (--no-glm), {len(glm_queue)} orphans dropped")

        if user_added:
            top_user = ', '.join(f"{t}({c})" for t, c in user_added.most_common(10))
            log(f"top user-edit additions: {top_user}")
        auto = mine_auto_hotwords(asr_records, jsonl['assistant'], user_added, set(manual), auto_budget, exclude_lc)
        log(f"auto-mined {len(auto)} candidate hotwords (budget {auto_budget})")

    final = list(manual) + [a['token'] for a in auto]
    final = [w for w in final if w.strip().lower() not in exclude_lc][:HOTWORD_BUDGET]

    added, removed = diff_with_previous(final)
    if added or removed:
        log(f"CHANGES: +{len(added)} added, -{len(removed)} removed")
        if added: log(f"  added:   {', '.join(added[:20])}{' ...' if len(added)>20 else ''}")
        if removed: log(f"  removed: {', '.join(removed[:20])}{' ...' if len(removed)>20 else ''}")
    else:
        log("no changes since last run")

    save_last_run(manual, auto, final)
    report_hotword_hits(final)
    report_snapper_hits()
    if not dry_run:
        prune_prompt_submissions()

    # ── 学到的替换规则 ──
    qualified_rules = [(k, v) for k, v in rule_counts.items() if v >= MIN_RULE_OCCURRENCES]
    qualified_rules.sort(key=lambda x: -x[1])
    learned_top = qualified_rules[:MAX_LEARNED_RULES]
    log(f"learned rules: {len(learned_top)} qualified (≥{MIN_RULE_OCCURRENCES} occurrences), keeping top {min(len(learned_top), MAX_LEARNED_RULES)}")
    if learned_top:
        for (w, r), c in learned_top[:10]:
            log(f"  ×{c}  '{w}' → '{r}'")

    # 合并 replacements：保留所有 manual，append 不重复的 learned
    current_rules = read_current_replacements()
    manual_rules = [r for r in current_rules if r.get('source') != 'learned']
    # 去重：如果 (from, to) 已存在于 manual 集合，跳过
    manual_pairs = {(r.get('from',''), r.get('to','')) for r in manual_rules}
    learned_payload = []
    for (w, r), _ in learned_top:
        if (w, r) in manual_pairs:
            log(f"  skip learned '{w}'→'{r}' — already in manual rules")
            continue
        learned_payload.append(build_learned_rule(w, r))
    final_rules = manual_rules + learned_payload

    if dry_run:
        log(f"DRY-RUN: would write {len(final)} hotwords and {len(final_rules)} rules ({len(manual_rules)} manual + {len(learned_payload)} learned) to {APP_DOMAIN}")
        log("FINAL hotwords (dry-run):")
        for i, w in enumerate(final, 1):
            print(f"  {i:2d}. {w}")
        if learned_payload:
            log("FINAL learned rules (dry-run):")
            for r in learned_payload:
                print(f"  '{r['from']}' → '{r['to']}'")
        return

    # CRITICAL: stop the app BEFORE writing UserDefaults.
    # Voice Brother's NSApplicationWillTerminate handler triggers AppConfig.save(),
    # which dumps the in-memory hotwords back to disk. If we write first and
    # kill second, the app's terminal save wipes out our update.
    was_running = is_app_running()
    if was_running:
        gracefully_stop_app()

    if not write_hotwords(final):
        log("ERROR hotwords write failed")
        if was_running and not no_restart:
            restart_app()
        sys.exit(1)
    log(f"OK wrote {len(final)} hotwords to {APP_DOMAIN}")

    if not write_replacements(final_rules):
        log("ERROR replacements write failed")
        if was_running and not no_restart:
            restart_app()
        sys.exit(1)
    log(f"OK wrote {len(final_rules)} replacement rules ({len(manual_rules)} manual + {len(learned_payload)} learned) to {APP_DOMAIN}")

    if was_running and not no_restart:
        restart_app()
    elif was_running and no_restart:
        log("--no-restart: leaving app stopped")
    else:
        log("app was not running — start it manually to pick up new hotwords")


def main():
    p = argparse.ArgumentParser(description="Voice Brother dynamic hotwords updater")
    p.add_argument('--dry-run', action='store_true', help="print only, don't write UserDefaults")
    p.add_argument('--no-restart', action='store_true', help="don't auto-restart Voice Brother after write")
    p.add_argument('--no-glm', action='store_true', help="skip the GLM orphan-review channel (faster dry-runs)")
    p.add_argument('--show', action='store_true', help="show current hotwords from UserDefaults and exit")
    p.add_argument('--show-rules', action='store_true', help="show current replacement rules and exit")
    p.add_argument('--reset-manual', action='store_true', help="re-snapshot current hotwords as manual-locked")
    args = p.parse_args()
    if args.show:
        cur = read_current_hotwords()
        print(f"Current hotwords ({len(cur)}):")
        for w in cur: print(f"  {w}")
        return
    if args.show_rules:
        rules = read_current_replacements()
        manual = [r for r in rules if r.get('source') != 'learned']
        learned = [r for r in rules if r.get('source') == 'learned']
        print(f"Current replacements: {len(manual)} manual + {len(learned)} learned = {len(rules)} total")
        if manual:
            print(f"\n— manual ({len(manual)}) —")
            for r in manual: print(f"  '{r.get('from','')}' → '{r.get('to','')}'")
        if learned:
            print(f"\n— learned ({len(learned)}) —")
            for r in learned: print(f"  '{r.get('from','')}' → '{r.get('to','')}'")
        return
    if args.reset_manual:
        ensure_state_dir()
        if MANUAL_FILE.exists():
            MANUAL_FILE.unlink()
            log("reset: removed manual file")
        manual = load_manual()
        log(f"reset: snapshotted {len(manual)} hotwords as manual-locked")
        return
    run(dry_run=args.dry_run, no_restart=args.no_restart, no_glm=args.no_glm)


if __name__ == '__main__':
    main()
