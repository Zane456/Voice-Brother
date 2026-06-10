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
import sys
import time
import bisect
import uuid
import difflib
import subprocess
import argparse
from pathlib import Path
from collections import Counter
from datetime import datetime, timedelta

try:
    import Levenshtein
except ImportError:
    Levenshtein = None  # only needed for user-edit mining; fail gracefully

APP_PROCESS_NAME = "VoiceBrother"
APP_BUNDLE_PATH = "/Applications/Voice Brother.app"

# ─── 路径配置 ───────────────────────────────────────────
HOME = Path.home()
HISTORY_DB = HOME / "Library/Application Support/VoiceBrother/history.db"
CLAUDE_PROJECTS = HOME / ".claude/projects"
APP_DOMAIN = "com.voicebrother.app"

SCRIPT_DIR = Path(__file__).resolve().parent
STATE_DIR = SCRIPT_DIR / "state"
MANUAL_FILE = STATE_DIR / "hotwords_manual.json"
LAST_RUN_FILE = STATE_DIR / "last_run.json"
LOG_FILE = STATE_DIR / "update.log"

# ─── 算法配置 ───────────────────────────────────────────
HOTWORD_BUDGET = 80
LOOKBACK_DAYS = 30
MIN_CLAUDE_FREQ = 5
MAX_ASR_RECALL_RATIO = 0.3   # ASR / Claude 召回率低于此值才算"漏识别"

# 对齐 ASR ↔ user message 的窗口（ASR 写入后多少秒内的 user msg 算同一次输入）
USER_EDIT_ALIGN_WINDOW = 90
USER_EDIT_MAX_LEVENSHTEIN = 40  # ASR 转写 vs user msg 编辑距离上限（用户改动留足空间）
USER_EDIT_BOOST = 30            # 用户手动编辑添加的 token 在打分中的额外权重

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

def load_asr_records(days: int):
    """返回 [{ts, text}]。text 优先用 raw_text（ASR 原始转写），fallback 到 text。"""
    if not HISTORY_DB.exists():
        log(f"FATAL: history.db not found at {HISTORY_DB}")
        sys.exit(2)
    conn = sqlite3.connect(str(HISTORY_DB))
    since = (datetime.now() - timedelta(days=days)).strftime('%Y-%m-%dT%H:%M:%S')
    rows = conn.execute(
        "SELECT created_at, text, raw_text FROM transcription_history WHERE created_at > ? ORDER BY created_at ASC",
        (since,)).fetchall()
    conn.close()
    out = []
    for ts_str, text, raw in rows:
        try:
            ts = datetime.fromisoformat((ts_str or '').replace('Z',''))
        except (ValueError, AttributeError):
            continue
        # raw_text 是 ASR 原始输出，没经过替换规则/语气词过滤，最贴近用户实际听到的
        # 如果跟 user message diff，这个对齐更准
        body = (raw or text or '').strip()
        if body:
            out.append({'ts': ts, 'text': body})
    return out


def load_jsonl_records(days: int):
    """返回 {'user': [{ts, text}], 'assistant': [{ts, text}]}。"""
    result = {'user': [], 'assistant': []}
    if not CLAUDE_PROJECTS.exists():
        log(f"WARN: claude projects dir not found at {CLAUDE_PROJECTS}")
        return result
    since = datetime.now() - timedelta(days=days)
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


def is_replacement_candidate(wrong: str, right: str) -> bool:
    """判断 (wrong, right) 是否值得作为替换规则。严格过滤是为了保精度——
    替换规则一旦生效会硬改所有匹配字符串，一条错规则比十条空规则更糟。"""
    if not wrong or not right or wrong == right: return False
    # 常用口语词做 wrong 必然每句误触发，无条件拒绝（好了→我的ext 事故）
    if wrong.strip(CJK_EDGE_PUNCT) in CJK_NON_LEARNABLE: return False
    if len(wrong) < 2: return False                       # 单字 wrong 误伤太多
    if len(right) < 2: return False                       # 单字 right 太通用（如"好""是"）
    if len(wrong) > RULE_MAX_WRONG_LEN: return False
    if len(right) > RULE_MAX_WRONG_LEN: return False
    if wrong in right or right in wrong: return False     # 半改动
    # wrong 必须含汉字——纯英文 wrong 容易跟正常英文混淆
    if not any('一' <= c <= '鿿' for c in wrong): return False
    # right 必须含字母数字或汉字，不能全标点
    if not any(c.isalnum() or '一' <= c <= '鿿' for c in right): return False
    # right 不能含句末/分隔标点——真正的术语替换不跨句
    if any(c in '。！？；…，,.;!?\n' for c in right): return False
    # 长度比例不能太悬殊（防止短词配到长 phrase 的 difflib 噪声）
    if len(right) > 2.5 * len(wrong) or len(wrong) > 2.5 * len(right): return False
    # wrong 是中文短术语（≤ 4 字），不接受完整 phrase——后者多半是 difflib 巧合匹配
    if sum(1 for c in wrong if '一' <= c <= '鿿') > 4: return False
    # right 必须以字母/数字为主（ASR 错听对应的真词通常是英文专名或数字 ITN，
    # 不应该是中文→中文替换——后者用 LLM polish 更合适，硬规则做反而危险）
    # 注意必须限定 ASCII：汉字的 str.isalnum() 也是 True，不限定的话
    # 中文→中文规则（然后→可以）会穿过这道闸
    alnum = sum(1 for c in right if c.isascii() and c.isalnum())
    if alnum / len(right) < 0.5: return False
    return True


def mine_replacement_rules(asr_records, user_records):
    """从配对的 ASR ↔ user message 挖出 (wrong, right) 替换规则候选。
    返回 (counts: Counter[(wrong, right) -> int], contexts: dict)。"""
    rule_counts = Counter()
    rule_ctx = {}
    if Levenshtein is None or not user_records or not asr_records:
        return rule_counts, rule_ctx
    user_ts = [m['ts'] for m in user_records]
    scanned = 0
    for asr in asr_records:
        lo = bisect.bisect_left(user_ts, asr['ts'] - timedelta(seconds=10))
        hi = bisect.bisect_right(user_ts, asr['ts'] + timedelta(seconds=USER_EDIT_ALIGN_WINDOW))
        if lo == hi: continue
        best, best_d = None, USER_EDIT_MAX_LEVENSHTEIN + 1
        head = asr['text'][:300]
        for i in range(lo, hi):
            d = Levenshtein.distance(head, user_records[i]['text'][:300])
            if d < best_d:
                best_d, best = d, user_records[i]
        if best is None or best_d > USER_EDIT_MAX_LEVENSHTEIN or best_d == 0: continue
        scanned += 1
        for wrong, right in extract_diff_spans(asr['text'], best['text']):
            if not is_replacement_candidate(wrong, right): continue
            rule_counts[(wrong, right)] += 1
            if (wrong, right) not in rule_ctx:
                rule_ctx[(wrong, right)] = asr['text'][:80]
    log(f"rule mining: scanned {scanned} edited pairs, found {len(rule_counts)} unique (wrong→right) candidates")
    return rule_counts, rule_ctx


def mine_user_edits(asr_records, user_records):
    """对每条 ASR 转写找配对的 user message，diff 出"用户手动新增的 token"。
    返回 (added_tokens Counter, replaced_pairs list)，前者是热词候选，后者是错听→真词候选。"""
    added = Counter()
    replaced = []
    if Levenshtein is None or not user_records or not asr_records:
        return added, replaced
    user_ts = [m['ts'] for m in user_records]
    matched = 0
    edited = 0
    for asr in asr_records:
        lo = bisect.bisect_left(user_ts, asr['ts'] - timedelta(seconds=10))
        hi = bisect.bisect_right(user_ts, asr['ts'] + timedelta(seconds=USER_EDIT_ALIGN_WINDOW))
        if lo == hi: continue
        # 在窗口内挑跟 ASR 文本编辑距离最小的 user msg
        best = None
        best_dist = USER_EDIT_MAX_LEVENSHTEIN + 1
        asr_head = asr['text'][:300]
        for i in range(lo, hi):
            um = user_records[i]
            # 用 head 段算距离防长消息干扰
            user_head = um['text'][:300]
            d = Levenshtein.distance(asr_head, user_head)
            if d < best_dist:
                best_dist = d
                best = um
        if best is None or best_dist > USER_EDIT_MAX_LEVENSHTEIN: continue
        matched += 1
        if best_dist == 0: continue  # 完全没改，跳过
        edited += 1
        asr_tokens = set(tokenize(asr['text']))
        user_tokens = set(tokenize(best['text']))
        # 用户加进去的 token = user 有 但 ASR 没有
        for tok in user_tokens - asr_tokens:
            added[tok] += 1
        # 简单的"替换"启发：如果删除一个 token + 添加一个 token，且字母数接近 → 可能是错听对应
        # 这里只做粗采，进一步精修需要 GLM 或拼音匹配
        removed = asr_tokens - user_tokens
        for r_tok in removed:
            for a_tok in (user_tokens - asr_tokens):
                if abs(len(r_tok) - len(a_tok)) <= 3:
                    replaced.append({'wrong': r_tok, 'right': a_tok, 'ctx': asr['text'][:60]})
    log(f"user-edit mining: matched {matched} ASR↔user pairs, {edited} edited, {len(added)} unique added tokens")
    return added, replaced


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

def mine_auto_hotwords(asr_records, assistant_records, user_added, manual_set, budget):
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

def run(dry_run: bool = False, no_restart: bool = False):
    log("=" * 60)
    log(f"START dry_run={dry_run} no_restart={no_restart} lookback={LOOKBACK_DAYS}d budget={HOTWORD_BUDGET}")

    manual = load_manual()
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
        user_added, _replaced = mine_user_edits(asr_records, jsonl['user'])
        if user_added:
            top_user = ', '.join(f"{t}({c})" for t, c in user_added.most_common(10))
            log(f"top user-edit additions: {top_user}")
        rule_counts, rule_ctx = mine_replacement_rules(asr_records, jsonl['user'])
        auto = mine_auto_hotwords(asr_records, jsonl['assistant'], user_added, set(manual), auto_budget)
        log(f"auto-mined {len(auto)} candidate hotwords (budget {auto_budget})")

    final = list(manual) + [a['token'] for a in auto]
    final = final[:HOTWORD_BUDGET]

    added, removed = diff_with_previous(final)
    if added or removed:
        log(f"CHANGES: +{len(added)} added, -{len(removed)} removed")
        if added: log(f"  added:   {', '.join(added[:20])}{' ...' if len(added)>20 else ''}")
        if removed: log(f"  removed: {', '.join(removed[:20])}{' ...' if len(removed)>20 else ''}")
    else:
        log("no changes since last run")

    save_last_run(manual, auto, final)

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
    run(dry_run=args.dry_run, no_restart=args.no_restart)


if __name__ == '__main__':
    main()
