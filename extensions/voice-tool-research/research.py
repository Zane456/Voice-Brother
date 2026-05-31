#!/usr/bin/env python3
"""
Voice Brother - 语音识别能力深度调研 extension（多 agent 多轮版）

每小时一个周期，单周期内执行 5 阶段流程，模拟一个"调研小组"：
  Step 1  planner    — 主 agent 规划本轮主题 + 5 个互斥子话题（防重复参考前轮）
  Step 2  5 subagents — 并发深挖（5 次并发 GLM 调用，每个负责 1 个子话题）
  Step 3  critic     — 主 agent 审查 5 份报告，找矛盾/盲点/需深挖处
  Step 4  followups  — 0-3 个跟进 subagent 二轮验证 critic 提出的问题
  Step 5  synthesizer — 主 agent 合成最终 REPORT.md（结构化、可执行）

共 12 轮，跑完自动 launchctl unload。每轮约 9-11 次 GLM 调用。
"""

import json
import os
import re
import sys
import subprocess
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from datetime import datetime

# ─── 路径 ───────────────────────────────────────────
HOME = Path.home()
VB_APP_SUPPORT = HOME / "Library/Application Support/VoiceBrother"
CREDENTIALS_FILE = VB_APP_SUPPORT / "credentials.json"
APP_DOMAIN = "com.voicebrother.app"

SCRIPT_DIR = Path(__file__).resolve().parent
STATE_DIR = SCRIPT_DIR / "state"
COUNTER_FILE = STATE_DIR / "counter.txt"
LOG_FILE = STATE_DIR / "runs.log"
INDEX_FILE = STATE_DIR / "INDEX.md"
PLIST_LABEL = "com.voicebrother.voice-tool-research"

TOTAL_ROUNDS = 12
SUBAGENTS_PER_ROUND = 5
MAX_FOLLOWUPS = 3
GLM_TIMEOUT_SEC = 180

# ─── Voice Brother 背景（注入到所有 prompt）───────────
VB_CONTEXT = """\
产品：Voice Brother（macOS 14+ 原生语音输入）
技术栈：Swift + SwiftUI + MLX
核心交互：按住 Fn 录音 → 松开 → ASR 转写 → 注入光标处
ASR 引擎：Qwen3-ASR (1.7B/0.6B, 本地 MLX) + Apple ASR (SFSpeechRecognizer) + 火山引擎 WebSocket
已有能力：
  - 动态热词学习（每天 22:00 跑，挖 ASR↔Claude jsonl 配对的 user 编辑信号）
  - 替换规则自学习（difflib 找 wrong→right 配对，learned 类型规则）
  - 多层文本后处理（filler 去除 / ITN / 用户替换规则 / 云端 LLM polish）
  - 录音浮窗（NSPanel + glassmorphism + 实时波形）
  - 会议纪要模式（双 Cmd 触发，独立 ASR 模型）
  - MLX cache governance（防 RSS 失控）
痛点（按优先级）：
  1. 英文专名错听（"Mac"→"马提卡/毛体卡"），热词机制有但需更智能
  2. 长句中的 filler 还有漏过滤
  3. 流式 ASR 没接通（当前 1.5s 定时器分段，不能边说边出字）
  4. 中英混说时英文部分识别率不稳定
约束：纯本地优先（隐私+无网），云端 polish 只做补刀；保持单按住交互；macOS-only"""

# ─── GLM API ────────────────────────────────────────

_creds_cache = None

def load_credentials():
    global _creds_cache
    if _creds_cache: return _creds_cache
    if not CREDENTIALS_FILE.exists():
        die(f"credentials file not found: {CREDENTIALS_FILE}")
    with open(CREDENTIALS_FILE) as f:
        creds = json.load(f)
    api_key = creds.get("llm.zai", "").strip()
    if not api_key:
        die("no llm.zai api key — configure GLM in Voice Brother first")
    out = subprocess.run(['defaults', 'export', APP_DOMAIN, '-'], capture_output=True, check=True).stdout
    import plistlib
    pl = plistlib.loads(out)
    llm_data = pl.get('llmCredentials')
    cfg = json.loads(llm_data.decode('utf-8')).get('zai', {}) if isinstance(llm_data, bytes) else {}
    base_url = (cfg.get('baseURL') or 'https://api.z.ai/api/anthropic/v1').rstrip('/')
    model = cfg.get('model') or 'glm-4.5-air'
    _creds_cache = (api_key, base_url, model)
    return _creds_cache


def call_glm(system_prompt: str, user_message: str, max_tokens: int = 4000, label: str = "") -> str:
    api_key, base_url, model = load_credentials()
    url = f"{base_url}/messages"
    body = {
        "model": model,
        "max_tokens": max_tokens,
        "system": system_prompt,
        "messages": [{"role": "user", "content": user_message}],
    }
    req = urllib.request.Request(
        url, data=json.dumps(body).encode('utf-8'), method='POST',
        headers={
            'Content-Type': 'application/json',
            'x-api-key': api_key,
            'anthropic-version': '2023-06-01',
        })
    try:
        with urllib.request.urlopen(req, timeout=GLM_TIMEOUT_SEC) as resp:
            data = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body_text = e.read().decode('utf-8', errors='ignore')[:500]
        raise RuntimeError(f"GLM HTTP {e.code}: {body_text}")
    except urllib.error.URLError as e:
        raise RuntimeError(f"GLM network error: {e}")
    content = data.get('content', [])
    parts = [b.get('text', '') for b in content if isinstance(b, dict) and b.get('type') == 'text']
    text = '\n'.join(parts).strip()
    if label:
        log(f"  [{label}] {len(text)} chars")
    return text


def parse_json_loose(text: str) -> dict:
    """LLM 输出的 JSON 容错解析：剥 markdown 代码块、删前后说明、找首个 {} 块"""
    text = text.strip()
    # 1. 剥 ```json ... ``` 围栏
    m = re.search(r'```(?:json)?\s*\n(.*?)\n```', text, re.DOTALL)
    if m:
        text = m.group(1).strip()
    # 2. 找首个完整 { ... } 块
    start = text.find('{')
    if start < 0:
        raise ValueError(f"no JSON found in:\n{text[:300]}")
    depth = 0
    for i in range(start, len(text)):
        if text[i] == '{': depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return json.loads(text[start:i+1])
    raise ValueError(f"unbalanced JSON in:\n{text[:300]}")


# ─── Step 1: Planner ───────────────────────────────

def call_planner(round_n: int, prior_topics_md: str) -> dict:
    """主 agent 规划本轮主题 + 5 个互斥子话题"""
    is_synthesis = (round_n == TOTAL_ROUNDS)
    if is_synthesis:
        system = "你是语音识别产品的首席调研负责人。本轮是综合轮——基于之前所有轮次的发现，输出可执行路线图。"
        user = f"""## Voice Brother 背景
{VB_CONTEXT}

## 之前 11 轮的标题与关键词
{prior_topics_md}

## 本轮任务（第 {round_n}/{TOTAL_ROUNDS}，综合轮）
规划 5 个**综合维度**，让 5 个 subagent 分别从各自维度给出"对 Voice Brother 的最终建议"：
- 必须覆盖："本周可做"、"本月可做"、"季度规划"、"不建议做"、"风险与失败点"
- 每个维度都基于前 11 轮的具体发现
- 每个维度要 actionable，能落到具体文件/技术选型

输出严格 JSON（不要任何解释文字）：
{{
  "title": "本轮综合主题",
  "rationale": "为什么这 5 个维度互补",
  "subtopics": [
    {{"slug": "this-week", "title": "本周可做", "focus_questions": ["..."]}},
    {{"slug": "this-month", "title": "本月可做", "focus_questions": ["..."]}},
    {{"slug": "this-quarter", "title": "季度规划", "focus_questions": ["..."]}},
    {{"slug": "not-recommended", "title": "不建议做", "focus_questions": ["..."]}},
    {{"slug": "risks", "title": "风险与失败点", "focus_questions": ["..."]}}
  ]
}}"""
    else:
        system = """你是语音识别产品的首席调研负责人，负责设计每一轮调研的角度。
你的任务：每轮选一个**与之前所有轮次都明显不重叠**的具体角度，深挖语音识别能力提升。"""
        user = f"""## Voice Brother 背景
{VB_CONTEXT}

## 之前已完成的轮次（不要重复！）
{prior_topics_md or "（无 — 这是第一轮）"}

## 本轮任务（第 {round_n}/{TOTAL_ROUNDS}）
规划一个**新角度**的调研主题，必须满足：
1. 跟之前轮次的角度完全不同（不只是 slug 不同，是切入点不同）
2. 围绕**语音识别能力**（ASR 准确率、延迟、个性化、鲁棒性、上下文理解、多场景适应等）
3. 拆 5 个**互斥的子话题**（每个 subagent 负责一个，子话题之间不能交叉）
4. 每个子话题给出 3-5 个 focus questions，引导 subagent 深挖具体细节

候选角度（仅供激发灵感，不要照抄）：
- 模型层：ASR 模型架构、量化、蒸馏、speculative decoding
- 算法层：beam search、CTC bias、热词 FST、上下文 prompt
- 数据层：ASR-LM rescoring、用户自适应、口音建模
- 工程层：流式管线、VAD、端点检测、turn-taking
- 后处理：标点、ITN、code-switching、N-best rescoring
- 评估：WER 测量、benchmark、A/B 测试
- 交互：低延迟反馈、错误纠正 UI、可视化
- 多语言：中英混说、专名识别、领域适配
- 学习闭环：用户编辑信号、被动学习、主动学习
- 系统：mic 抢占、降噪、音频前处理

输出严格 JSON（不要任何解释或代码围栏）：
{{
  "title": "本轮主题（短，10 字内）",
  "angle": "本轮的独特切入角（1 句）",
  "rationale": "为什么这个角度还没覆盖、为什么对 VB 重要（2-3 句）",
  "subtopics": [
    {{
      "slug": "kebab-case-slug",
      "title": "子话题标题",
      "focus_questions": ["问题1", "问题2", "问题3"]
    }},
    ... 共 5 个
  ]
}}"""
    raw = call_glm(system, user, max_tokens=2500, label="planner")
    return parse_json_loose(raw)


# ─── Step 2: Subagents（并发）────────────────────────

def call_subagent(round_n: int, round_title: str, subtopic: dict, agent_idx: int) -> str:
    system = f"""你是语音识别领域的资深技术研究员（subagent #{agent_idx}/5）。
你负责本轮（第 {round_n} 轮）调研的一个具体子话题。其他 4 个 subagent 在并行做不同子话题。
你的输出会被首席调研员综合到最终报告里。"""

    focus_qs = "\n".join(f"  - {q}" for q in subtopic.get('focus_questions', []))
    user = f"""## Voice Brother 背景
{VB_CONTEXT}

## 本轮主题
{round_title}

## 你的子话题：{subtopic['title']}
（slug: {subtopic['slug']}）

## 要回答的 focus questions
{focus_qs}

## 输出要求
中文 markdown，1500-2500 字，结构：

### 子话题综述（150 字）
[你这一块要解决的核心问题、为什么对 VB 重要]

### 具体发现（每个 200-400 字，至少 5 个）
对每个项目/算法/方案：
- **名字** + GitHub URL（如已知）/论文标题
- **核心做了什么**（1-2 句）
- **技术细节**：算法关键点、复杂度、依赖
- **对 Voice Brother 的具体可借鉴点**：
  - 涉及哪个模块/文件（如 QwenASREngine.swift / FillerRemover.swift / VoiceService.swift）
  - 改动量估计（行数 / 工作日）
  - 预期收益（准确率提升 / 延迟降低 / 资源占用变化）
- **可行性**：高/中/低 + 具体理由
- **风险**：可能的失败模式

### 反向思考（100-200 字）
[这个子话题里的"反共识"观点：哪些热门方案其实不值得做？]

### top 3 优先级
[从你给出的所有方案中选 3 个最值得 VB 投入的，按 ROI 排序]

要求：信息密度高、可执行、不要凑字数。如果某项你不确定准确性，明确标注"待验证"。"""
    return call_glm(system, user, max_tokens=4500, label=f"subagent-{agent_idx}")


def run_subagents_parallel(round_n: int, plan: dict) -> list:
    title = plan.get('title', '')
    subtopics = plan.get('subtopics', [])[:SUBAGENTS_PER_ROUND]
    results = [None] * len(subtopics)
    with ThreadPoolExecutor(max_workers=SUBAGENTS_PER_ROUND) as ex:
        futures = {
            ex.submit(call_subagent, round_n, title, st, i + 1): i
            for i, st in enumerate(subtopics)
        }
        for fut in as_completed(futures):
            i = futures[fut]
            try:
                results[i] = fut.result()
            except Exception as e:
                log(f"  subagent-{i+1} FAILED: {e}")
                results[i] = f"# 子话题 {subtopics[i]['title']}\n\n**[此 subagent 失败]** {e}"
    return results


# ─── Step 3: Critic ────────────────────────────────

def call_critic(plan: dict, subagent_reports: list) -> dict:
    """critic 输出 markdown 而非 JSON（更鲁棒），脚本用正则提取 follow-up questions。"""
    system = """你是语音识别调研的资深质检员。你的任务：审查 5 个 subagent 的产出，找出
矛盾、盲点、可疑断言（LLM 幻觉嫌疑），并给出需要二轮验证的具体问题。

特别注意识别幻觉的征兆：
- 编造的文件名（如 ContextPredictor.swift 这种听起来对但实际不存在）
- 精确到行数的改动估计（"改 350 行代码"通常是猜的）
- 精确百分比的收益预测（"提升 25%" 多数没数据支撑）
- 编造的论文标题或 GitHub 仓库"""

    reports_concat = ""
    for i, r in enumerate(subagent_reports, 1):
        reports_concat += f"\n\n--- SUBAGENT {i} ---\n{r[:3000]}\n"

    user = f"""## 本轮规划
{json.dumps(plan, ensure_ascii=False, indent=2)}

## 5 个 subagent 的输出（每个截断到 3000 字）
{reports_concat}

## 输出格式（**markdown，不要 JSON**）

### 关键发现
- [subagent 1 最有价值的 1-2 个发现]
- [subagent 2 ...]
- [...5 条]

### 矛盾点
- [subagent X 说 A，subagent Y 说 B，谁对？]
- [...或写 "无明显矛盾"]

### 盲点
- [哪个重要问题没人回答]
- [...或写 "无明显盲点"]

### 可疑断言（需核验）
- [具体哪句话像 LLM 幻觉、为什么]
- [...]

### 是否需要 follow-up
回答：YES / NO

### Follow-up 问题（如 YES，列 1-3 个）
1. [具体问题。要核验什么 / 为什么 / 期待什么形式答案]
2. [...]
3. [...]"""
    raw = call_glm(system, user, max_tokens=2500, label="critic")

    # 用正则提取 follow-up
    needs_fu = bool(re.search(r'是否需要\s*follow-up.*?\n.*?\bYES\b', raw, re.IGNORECASE | re.DOTALL))
    questions = []
    if needs_fu:
        # 找 "Follow-up 问题" 这一节后的编号项
        m = re.search(r'Follow-up\s*问题.*?\n((?:.*\n?)*)', raw, re.IGNORECASE)
        if m:
            section = m.group(1)
            for line in section.split('\n'):
                line = line.strip()
                # 匹配 "1. xxx" / "1) xxx" / "- xxx"
                qm = re.match(r'^(?:\d+[.)、]|-|\*)\s*(.{20,})', line)
                if qm:
                    questions.append(qm.group(1).strip())
                if len(questions) >= MAX_FOLLOWUPS: break
    return {
        "raw_markdown": raw,
        "needs_followup": needs_fu and len(questions) > 0,
        "followup_questions": questions,
    }


# ─── Step 4: Followup Subagents ─────────────────────

def call_followup(question: str, idx: int) -> str:
    system = f"""你是语音识别领域的资深 fact-checker（follow-up subagent #{idx}）。
你的任务：针对一个具体问题做二轮深挖，给出更可靠的答案。
被问到的内容是首席质检员认为"需要核验/补充"的——你要给出比第一轮更精确、可引用的回答。"""
    user = f"""## Voice Brother 背景
{VB_CONTEXT}

## 二轮调研问题
{question}

## 输出要求
中文 markdown，800-1500 字：
1. **问题拆解**：你怎么理解这个问题，分几个面回答
2. **答案**：具体、可引用，给项目名/论文/URL/版本号/benchmark 数字
3. **置信度**：高/中/低 + 理由
4. **对 Voice Brother 的影响**：这个答案改不改变之前的优先级判断"""
    return call_glm(system, user, max_tokens=2500, label=f"followup-{idx}")


def run_followups_parallel(questions: list) -> list:
    qs = questions[:MAX_FOLLOWUPS]
    results = [None] * len(qs)
    with ThreadPoolExecutor(max_workers=len(qs)) as ex:
        futures = {ex.submit(call_followup, q, i + 1): i for i, q in enumerate(qs)}
        for fut in as_completed(futures):
            i = futures[fut]
            try:
                results[i] = fut.result()
            except Exception as e:
                log(f"  followup-{i+1} FAILED: {e}")
                results[i] = f"**[follow-up 失败]** {e}"
    return results


# ─── Step 5: Synthesizer ───────────────────────────

def call_synthesizer(round_n: int, plan: dict, subagent_reports: list,
                     critique: dict, followups: list) -> str:
    system = """你是语音识别调研的首席编辑。你的任务：把 1 份规划 + 5 份 subagent 报告 +
1 份 critic 审查 + 0-3 份 follow-up 综合成一份最终 REPORT.md，给 Voice Brother 团队阅读。

输出要求：
- 结构清晰、信息密度高、可执行
- 删除 subagent 之间的重复内容
- 采纳 critic 的纠正（被标记 suspicious 的要么删除要么注明"待验证"）
- 采纳 followup 的新信息（如有）
- 最后给出本轮的 top 3 行动建议（针对 Voice Brother）"""

    subagents_concat = ""
    for i, r in enumerate(subagent_reports, 1):
        st = plan['subtopics'][i - 1] if i - 1 < len(plan.get('subtopics', [])) else {}
        subagents_concat += f"\n\n## SUBAGENT {i} — {st.get('title','')}\n{r}\n"

    followups_concat = "\n\n（无 follow-up）" if not followups else "".join(
        f"\n\n## FOLLOWUP {i+1}\n{r}" for i, r in enumerate(followups))

    user = f"""## 本轮规划
**主题**：{plan.get('title','')}
**切入角**：{plan.get('angle', '')}
**规划理由**：{plan.get('rationale', '')}

## 5 个 subagent 的完整报告
{subagents_concat}

## critic 审查（markdown）
{critique.get('raw_markdown', '（无 critique）')}

## follow-up 调研结果
{followups_concat}

## 任务
合成一份最终 REPORT.md，结构：

# 第 {round_n} 轮调研报告：{{主题}}

## 调研切入角
[1-2 句]

## 核心发现（5 大块，对应 5 个子话题）
### {{子话题 1 标题}}
[整合 subagent 1 + critic 纠正 + followup 补充，去重去废话，500-800 字]
- 关键项目/方案：...
- 对 VB 的可借鉴点：...

[同样写 5 块]

## 跨子话题的洞察
[5 个 subagent 加在一起浮现的新模式 / 共识 / 冲突的解决]

## 本轮 Top 3 行动建议
[3 条针对 VB 的具体改进，每条含：动什么文件、改动量、预期收益、风险]

## 待验证 / 下轮深挖
[本轮没解决的问题，留给后续轮次]"""
    return call_glm(system, user, max_tokens=6000, label="synthesizer")


# ─── 状态 / 索引 ────────────────────────────────────

def get_counter() -> int:
    if not COUNTER_FILE.exists(): return 0
    try: return int(COUNTER_FILE.read_text().strip())
    except (ValueError, OSError): return 0

def set_counter(n: int):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    COUNTER_FILE.write_text(str(n))

def log(msg: str):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    line = f"[{ts}] {msg}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, 'a') as f:
            f.write(line + '\n')
    except OSError:
        pass

def die(msg: str):
    log(f"FATAL: {msg}")
    sys.exit(1)


def collect_prior_topics() -> str:
    """读所有已完成轮次的 plan.json，输出"标题 + 子话题列表"作为防重复 hint"""
    parts = []
    for n in range(1, TOTAL_ROUNDS + 1):
        plan_f = STATE_DIR / f"round-{n:02d}" / "plan.json"
        if not plan_f.exists(): continue
        try:
            plan = json.loads(plan_f.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        subs = plan.get('subtopics', [])
        sub_lines = '; '.join(s.get('slug', '?') for s in subs)
        parts.append(f"- 第 {n} 轮：{plan.get('title','')}（角度：{plan.get('angle','')}）\n  子话题：{sub_lines}")
    return '\n'.join(parts)


def update_index(round_n: int, plan: dict):
    """每轮跑完后维护 INDEX.md"""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    lines = ["# Voice Brother 语音工具调研索引", "", f"_最后更新：{datetime.now().isoformat(timespec='seconds')}_", ""]
    for n in range(1, TOTAL_ROUNDS + 1):
        plan_f = STATE_DIR / f"round-{n:02d}" / "plan.json"
        report_f = STATE_DIR / f"round-{n:02d}" / "REPORT.md"
        if not plan_f.exists():
            lines.append(f"- [ ] **第 {n} 轮** — 未开始")
            continue
        try:
            p = json.loads(plan_f.read_text())
        except (json.JSONDecodeError, OSError):
            p = {}
        title = p.get('title', '?')
        angle = p.get('angle', '')
        if report_f.exists():
            lines.append(f"- [x] **第 {n} 轮 — {title}** — [REPORT](round-{n:02d}/REPORT.md)")
            if angle: lines.append(f"      _{angle}_")
        else:
            lines.append(f"- [~] **第 {n} 轮 — {title}** — 进行中")
    INDEX_FILE.write_text('\n'.join(lines) + '\n')


def unload_launchd():
    plist = HOME / "Library/LaunchAgents" / f"{PLIST_LABEL}.plist"
    if plist.exists():
        log(f"all rounds done — unloading launchd job {PLIST_LABEL}")
        subprocess.run(['launchctl', 'unload', str(plist)], capture_output=True)


# ─── 主流程 ──────────────────────────────────────────

def run_round(round_n: int):
    round_dir = STATE_DIR / f"round-{round_n:02d}"
    round_dir.mkdir(parents=True, exist_ok=True)

    log("=" * 60)
    log(f"ROUND {round_n}/{TOTAL_ROUNDS} START")

    # Step 1: planner
    prior = collect_prior_topics()
    log(f"Step 1: planner (with {prior.count(chr(10).join(['- 第'])) + (1 if prior else 0)} prior rounds context)")
    try:
        plan = call_planner(round_n, prior)
    except Exception as e:
        die(f"planner failed: {e}")
    (round_dir / "plan.json").write_text(json.dumps(plan, ensure_ascii=False, indent=2))
    log(f"  → '{plan.get('title','')}' / {len(plan.get('subtopics',[]))} subtopics")

    # Step 2: 5 subagents
    log(f"Step 2: dispatching {len(plan.get('subtopics',[]))} subagents in parallel")
    sub_reports = run_subagents_parallel(round_n, plan)
    for i, r in enumerate(sub_reports, 1):
        st = plan['subtopics'][i - 1]
        (round_dir / f"subagent-{i:02d}-{st['slug']}.md").write_text(r or "")

    # Step 3: critic
    log("Step 3: critic review")
    try:
        critique = call_critic(plan, sub_reports)
    except Exception as e:
        log(f"  critic failed: {e} — proceeding without critique")
        critique = {"needs_followup": False, "followup_questions": []}
    (round_dir / "critique.md").write_text(critique.get("raw_markdown", ""))
    (round_dir / "critique.json").write_text(json.dumps(
        {k: v for k, v in critique.items() if k != "raw_markdown"},
        ensure_ascii=False, indent=2))

    # Step 4: followups (conditional)
    followups = []
    fq = critique.get('followup_questions', []) if critique.get('needs_followup') else []
    if fq:
        log(f"Step 4: dispatching {min(len(fq), MAX_FOLLOWUPS)} follow-up subagents")
        followups = run_followups_parallel(fq)
        for i, r in enumerate(followups, 1):
            (round_dir / f"followup-{i:02d}.md").write_text(r or "")
    else:
        log("Step 4: skipped (critic decided no follow-up needed)")

    # Step 5: synthesizer
    log("Step 5: synthesizer")
    try:
        final = call_synthesizer(round_n, plan, sub_reports, critique, followups)
    except Exception as e:
        die(f"synthesizer failed: {e}")
    (round_dir / "REPORT.md").write_text(final)
    log(f"  REPORT.md written ({len(final)} chars)")

    update_index(round_n, plan)
    set_counter(round_n)
    log(f"ROUND {round_n} DONE")


def run():
    counter = get_counter()
    if counter >= TOTAL_ROUNDS:
        log(f"already at {counter}/{TOTAL_ROUNDS} — self-unloading")
        unload_launchd()
        return
    round_n = counter + 1
    try:
        run_round(round_n)
    except SystemExit:
        raise
    except Exception as e:
        log(f"ROUND {round_n} FAILED: {e}")
        sys.exit(1)
    if round_n >= TOTAL_ROUNDS:
        unload_launchd()


def main():
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument('--reset', action='store_true', help='reset counter to 0')
    p.add_argument('--status', action='store_true', help='show progress')
    p.add_argument('--round', type=int, help='force run a specific round number (debug)')
    args = p.parse_args()
    if args.reset:
        if COUNTER_FILE.exists(): COUNTER_FILE.unlink()
        log("counter reset")
        return
    if args.status:
        c = get_counter()
        print(f"progress: {c}/{TOTAL_ROUNDS}")
        for n in range(1, TOTAL_ROUNDS + 1):
            d = STATE_DIR / f"round-{n:02d}"
            report = d / "REPORT.md"
            plan = d / "plan.json"
            if report.exists():
                try: title = json.loads(plan.read_text()).get('title','?')
                except: title = '?'
                print(f"  [✓] round {n:02d} — {title}")
            elif plan.exists():
                print(f"  [~] round {n:02d} — in progress")
            else:
                print(f"  [ ] round {n:02d}")
        return
    if args.round:
        run_round(args.round)
        return
    run()


if __name__ == '__main__':
    main()
