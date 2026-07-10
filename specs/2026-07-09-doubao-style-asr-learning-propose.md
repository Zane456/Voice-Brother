# 豆包式 ASR 学习系统 — 设计提案

> 2026-07-09。目标：借鉴豆包输入法的准确度机制，给 Voice Brother 建一套**引擎无关**的语音纠错学习系统。
> 约束（用户拍板）：无论用哪个 ASR 引擎（Qwen / Volcano / Apple）都必须生效 → 一切能力坐在 ASR 输出之后。

## 1. 背景：豆包怎么做（本地逆向结论）

逆向 `/Library/Input Methods/DoubaoIme.app`（OimeEngine 二进制 + 用户词典目录）：

- 识别本体 = 云端流式（SAMI），本地无 ASR 模型
- **拼音层纠错**：ASR 输出转注音 → 与用户词典同音匹配 → 替换（`AsrWordConversion`）
- **纠错学习**：用户改字 → `AsrUserCorrectDict::Add`，硬约束 = **同音 + 同长**（`length not equal` / `zhuyin failed` 直接拒）
- **专名学习**：本地 LAC 模型从用户打字内容抽专名 → `asr_user_ner_dict.dat`（带词频增减）
- contextBefore（光标前文字喂识别）：引擎特定，**不抄**（违反引擎无关约束 + FocusObserver 隐私红线「从不读 value」保留）

## 2. 现状调查：管道已存在，但配对层是坏的（实证）

`extensions/dynamic-hotwords/update_hotwords.py` 的 `mine_replacement_rules()` 已实现「history.db ↔ Claude 会话 jsonl 对齐挖规则」，每晚 22:00 跑。**2026-07-09 复现昨晚挖掘，930 个候选逐个检查：没有一条是真正的 ASR 错字对。**

病根 = 配对算法（时间窗 90s + Levenshtein ≤40 取最近）在真实使用模式下必然失败：

1. 用户一条消息由多段语音拼成 → 每段 ASR 都跟整条消息配 → 5 条 ASR 抢 1 条消息
2. 短消息是万能钥匙（「不用切」跟任何 12 字内 ASR 距离都 ≤40）
3. 阈值 40 宽到无关句子也能过

连带后果（均已实证）：
- `unedited: 0` —— 4066 对配对没有一对 dist==0（换 processed text 重跑仍然是 0）
- 北极星指标 `mean_edit_rate ≈ 0.54` 测的是**乱配率**，不是编辑率，历史数据作废
- 中→中 ASCII 闸（`is_replacement_candidate` 末行）拦下的候选全是垃圾——**闸是防线不是病根，配对修好前不得开闸**

app 内 `CorrectionLearningEngine`（历史页手动编辑触发）逻辑健康但信号死亡：6–7 月 11739 次转写，用户纠错 0 次（用户对大模型说话，错字靠大模型意会，无动机手动改）。

## 3. 目标 / 非目标

**目标**
- G1 拼音层运行时纠错：热词表驱动，同音错字当场纠，不依赖任何学习信号
- G2 学习信号源修复：hook 精确配对，从用户真实提交里挖 (错词→正词)
- G3 中→中规则安全开闸：拼音闸（同音+同长）替代一刀切 ASCII 闸
- G4 北极星指标 v2：真实编辑率，可信趋势线

**非目标**
- contextBefore / 读输入框内容（隐私红线保留）
- n-gram 重打分（无数据源）、云端词库下发、做成输入法
- 模糊音等价类（zh/z、n/l）第一版不做，留升级位
- 本地 NER 挖专名（NLTagger 中文 NER 效果存疑，现有 Claude 回复挖词已覆盖，YAGNI）

## 4. 架构：两条独立的腿

```
腿1（运行时，当场见效）                腿2（学习，越用越准）
ASR 输出                              CC UserPromptSubmit hook
  → TextProcessor Layer1/2              → prompt_submissions.jsonl
  → 【新】PhoneticCorrector             → 夜间脚本锚定对齐 (vs history.db 注入记录)
     （热词表同音同长纠错）               → 形态闸 + 拼音闸 + 频次闸 + raw_text 回查
  → 替换规则（手动+已学）                → learned 规则 → UserDefaults → app 迁移
  → LLM polish（可选）                  → CorrectionLearningEngine.activeRules
  → 注入                                → 回到腿1 的替换规则阶段生效
```

两腿共享：热词表（ConfigManager.hotwords）、学习词典（learned_rules.json）、拼音工具（PinyinMatcher）。
任一腿单独存在都成立；腿2 挂掉不影响腿1（隔离原则与 CorrectionLearningEngine 现状一致）。

## 5. 组件设计

### 5.1 PinyinMatcher（新，Shared 层或 Backend/Voice/）

- 职责：汉字串 → 无调拼音串；两串同音判定
- 实现：`CFStringTransform(kCFStringTransformMandarinLatin)` → `StripDiacritics`，NSCache 缓存
- 多音字：取系统默认读音。两侧同转换器 → 系统性偏差部分抵消；剩余漏报可接受（保守方向）
- 接口：`pinyin(of: String) -> String`、`isHomophone(_:_:) -> Bool`（等长 + 拼音相同）

### 5.2 PhoneticCorrector（新，Backend/Voice/）— 腿1

- 时机：`TextProcessor.process` 内，ITN 之后、applyReplacements 之前
- 开关：`ConfigManager.phoneticCorrectionEnabled`（默认开；关闭时 process 链路与今日完全一致）
- 算法：对每个热词（含 learned 规则的 to 词）取字数 L → 在文本上滑 L 字窗口 → 窗口与热词**同音（无调）且不同字** → 替换
- 只处理纯 CJK 窗口；英文/混合热词跳过（英文无同音字问题，现有机制已覆盖）
- 防误伤：
  - 同长硬约束（豆包同款）
  - 命中记账进现有 `hotword_hits.json` 体系（`phonetic_hits`），HistoryTab 可见 raw→corrected 对照
  - 用户在历史页反向编辑 → 现有 REVERT 机制照常撤销
- 性能：80 热词 × ~100 字文本，拼音有缓存，单次转写 <1ms 量级，忽略不计

### 5.3 UserPromptSubmit hook（新，extensions/cc-prompt-log/）— 腿2 信号源

- `~/.claude/settings.json` 挂 UserPromptSubmit → 单行脚本把 `{ts, prompt}` append 到
  `~/Library/Application Support/VoiceBrother/learning/prompt_submissions.jsonl`（0600）
- 要求：同步执行 <50ms（shell + jq 或 python -c，不 import 重库）
- 滚动：夜间脚本挖完顺手清 >30 天记录
- 覆盖范围：仅 Claude Code 场景（用户 ~90% 语音用量在 CC）；其他 app 场景不学，只享受腿1

### 5.4 挖掘侧改造（update_hotwords.py）— 腿2 主体

配对算法整体替换（旧时间窗猜配对废弃）：

1. 数据源：prompt_submissions.jsonl（确切提交）×
   history.db `transcription_history`（确切注入：text=注入文本、raw_text=ASR 原文、created_at）
2. 对每条提交，取提交前 10 分钟内的注入记录，按时间序逐条做**锚定对齐**：
   注入文本在提交文本中找最佳匹配窗口，相似度 = 1 − lev/max(len)，**≥0.85 才锚定成功**；
   锚定失败（用户大幅改写）的段落**不直接丢弃**——进 GLM 复核通道（见 2b）
2b. **GLM 复核通道**（用户提议，回收大改段落里的错字信号）：
   锚定失败的（注入片段, 提交文本）对攒批，夜间调 z.ai GLM API 一次性判断
   「语音原文 vs 最终提交，其中哪些改动是 ASR 听错字（而非用户改说法）」，
   输出 (wrong, right) 候选。**GLM 候选不享受任何豁免，照过第 4 步全部闸门**
   （尤其拼音闸——防 LLM 幻觉）。GLM 调用失败 = 该批静默跳过，主链路不受影响
3. 锚定成功的（注入片段 ↔ 提交窗口）做 difflib 字符级 diff，提取 replace spans
4. 候选过滤链（顺序执行）：
   - 现有形态闸（`is_replacement_candidate`，去掉末行 ASCII 闸，改为 ↓）
   - **拼音闸**：中→中规则要求 wrong/right 同长 + 无调同音（pypinyin 初筛）；英文侧维持原 ASCII 规则
   - **raw_text 回查**：wrong 必须也出现在该条 `raw_text` 中，否则丢弃
     （规则应用在 polish 之前的文本上；wrong 若是 polish 产物，学了也永不命中 = 死规则）
   - 频次闸：同一 (wrong→right) 出现 ≥2 次
5. 写入链沿用现状：`build_learned_rule` → UserDefaults → app 启动 `migrateOrphanedLearnedRules` → `evictNonLearnableRules` 兜底

### 5.5 Swift 端 learn() 同步加拼音闸

- `CorrectionLearningEngine.learn()` 在 ITN 闸后新增：中→中 pair 必须同长同音（PinyinMatcher 终审），否则 SKIP + journal 记原因
- `evictNonLearnableRules()` 同步扫描：清掉存量/脚本漏进的不同音中→中规则
- 双端一致性：Python pypinyin 初筛，**Swift CFStringTransform 为唯一权威**，不一致时 evict 兜底（沿用黑名单双份同步先例，CLAUDE.md 记一条）

### 5.6 北极星指标 v2

- 只统计锚定成功的配对；`edit_rate = diff 字符数 / 锚定窗口长度`
- `unedited`（dist==0）恢复物理意义，作为配对修复的验收信号
- 旧 `edit_distance_daily.json` 归档为 `.v1-invalid`，新文件从零累积，文档标注不可比

## 6. 数据流（腿2 全链路）

```
用户按住说话 → ASR raw_text → 处理 → 注入 text（history.db 落库）
用户（可能手改/补打）→ 提交给 Claude → hook 记 {ts, prompt}
夜间 22:00 → 锚定对齐 → diff → 四道闸 → learned rule → UserDefaults
app 下次启动 → migrate → activeRules → 下一次转写自动应用（腿1 的替换阶段）
用户若发现误纠 → 历史页反向编辑 → REVERT 撤销（现有机制）
```

## 7. 失败模式与防线

| 失败模式 | 防线 |
|---|---|
| 手打新增内容被当成 ASR 错误 | 锚定 ≥0.85 + 整段丢弃 + 频次 ≥2 |
| 学出「好了→我的ext」类全局误触发 | 拼音闸（不同音不学）+ 停用词表（保留）+ evict 兜底 |
| 学出 polish 后才存在的死规则 | raw_text 回查 |
| PhoneticCorrector 误纠正确词 | 同长同音硬约束 + 记账可见 + REVERT 可撤 |
| hook 挂了/被删 | 腿2 静默停摆，腿1 与现有全部功能不受影响 |
| GLM 幻觉出假错字对 | GLM 候选与机械候选同闸（拼音+同长+频次），无豁免 |
| GLM API 挂/超时 | 该批跳过，小改动的机械学习照常 |
| 两端拼音实现分歧 | Swift 为权威，evict 每次启动兜底清扫 |

## 8. 验收标准

1. 构建绿 + 现有行为零回归（PhoneticCorrector 关闭时链路与今日完全一致；提供 ConfigManager 开关）
2. PhoneticCorrector 单测：同音同长替换命中、不同长不替、多音字不误替、英文热词跳过
3. 锚定对齐用真实 30 天数据回放：抽查 20 对锚定样本人工确认无乱配；`unedited > 0`
4. 拼音闸单测：张争→张诤（学）、好了→我的ext（拒：不同音不同长）、二十→20（拒：ITN 闸）
5. 观察期一周：learning.log 出现 LEARN 行且规则人工抽查合理；`phonetic_hits` 有命中记录；北极星 v2 出数
6. 回归红线：learned_rules.json 不得出现不同音的中→中规则（grep 验证脚本）

## 9. 实施顺序

1. **P1 hook 先装**（数据从今天开始积累，挖掘改造完成时已有存量）
2. **P2 腿1**：PinyinMatcher + PhoneticCorrector + 单测 + 构建重启（立刻有体感）
3. **P3 Swift 拼音闸**：learn() + evict + CLAUDE.md 同步先例记录
4. **P4 挖掘改造**：锚定对齐 + GLM 复核通道 + 四道闸 + 指标 v2（跑在 P1 积累的数据上）
5. **P5 观察一周**：按验收标准 5/6 复查，决定是否放宽（模糊音、频次阈值）

依赖：P2/P3 无依赖可并行；P4 依赖 P1 的数据；P5 依赖全部。
