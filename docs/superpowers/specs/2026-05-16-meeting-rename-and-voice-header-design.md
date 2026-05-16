# 「会议」→「对话记录」改名 + 语音页小标题精简 — 设计文档

> 日期：2026-05-16
> 范围：用户可见文字（多文件）+ VoiceSettingsSection

## 背景与问题

两件相关的 UI 一致性诉求：

1. **语音页冗余小标题**：`VoiceTab` 已有页面大标题「语音输入」，其下的
   `VoiceSettingsSection` 又有一个 `SectionHeader(title: "语音设置")` 小标题——
   两层标题冗余。用户要求删掉「语音设置」小标题，页面只留大标题「语音输入」。
2. **功能改名**：把「会议」功能整体改名为「对话记录」，覆盖所有用户可见文字。

## 目标

- 删除 `VoiceSettingsSection` 中的「语音设置」`SectionHeader`
- 把所有用户可见的「会议」相关文字按下方清单改为「对话记录」体系措辞

## 非目标

- **不改任何代码符号**：`MeetingService`、`MeetingState`、`MeetingTab`、
  `.meeting` 枚举 case、`meetingASRModel`、`.swift` 文件名等全部保持原样，
  只改字符串字面量（显示文字）
- 不删会议页的「会议设置」小标题（用户明确只删语音页的；该小标题改名为
  「对话记录设置」）
- 不改旧的已生成文件名——文件名前缀改动只影响**新**生成的文件
- 不改 LLM 提示词里的「会议」措辞（保留有助模型理解任务，改了无功能收益）
- 不改代码注释、隐私模式说明中泛指真实会议的「内部会议」

## 设计

### Part A — 删除语音页小标题

`Frontend/Tabs/Sections/VoiceSettingsSection.swift`：删除 `body` 中第一行
`SectionHeader(title: "语音设置")`。VStack `spacing: 16` 不变，第一张卡
（`triggerKeyCard`）直接成为首个元素。`VoiceTab` 的大标题「语音输入」不动。

### Part B — 「会议」→「对话记录」改名清单

下表为全部改动项，已经用户逐组确认「全部按建议」。位置为文件名:行号（行号以
本设计撰写时为准，实施时以实际匹配字符串为准）。

#### 第 1 组 · Tab 与导航标签
| 位置 | 现在 | 改为 |
|---|---|---|
| MainWindow.swift:17 | 会议（tab 名 rawValue） | 对话记录 |
| MainWindow.swift:35 | 会议纪要（窗口标题） | 对话记录 |
| MeetingTab.swift:17 | 会议（页面大标题） | 对话记录 |
| HistoryTab.swift:13 | 会议录音（历史分段 rawValue） | 对话记录 |

#### 第 2 组 · 会议页按钮 / 状态文字
| 位置 | 现在 | 改为 |
|---|---|---|
| MeetingTab.swift:100 | 开始会议 / 停止会议 | 开始记录 / 停止记录 |
| MeetingTab.swift:128 | 打开会议记录文件夹 | 打开对话记录文件夹 |
| MeetingTab.swift:147/149 | 正在加载会议模型… | 正在加载识别模型… |
| MeetingTab.swift:153 | 准备录制会议 | 准备开始记录 |
| MeetingTab.swift:162 | 即可启动会议 | 即可开始记录 |
| Types.swift:57 | 加载会议模型... | 加载识别模型... |
| Types.swift:60 | 生成会议摘要... | 生成对话摘要... |
| MeetingService.swift:213 | 会议录制失败 | 记录失败 |

#### 第 3 组 · 设置页文字
| 位置 | 现在 | 改为 |
|---|---|---|
| MeetingSettingsSection.swift:13 | 会议设置（小标题，保留不删） | 对话记录设置 |
| MeetingSettingsSection.swift:83 | 会议固定使用本地 Qwen… | 对话记录固定使用本地 Qwen… |
| MeetingSettingsSection.swift:206 | …自动生成会议摘要 | …自动生成对话摘要 |
| MeetingSettingsSection.swift:224 | 会议摘要提示词 | 对话摘要提示词 |
| MeetingSettingsSection.swift:292 | …选择一个会议类型… | …选择一个对话类型… |
| MeetingSettingsSection.swift:308 | 保存为会议摘要模板 | 保存为对话摘要模板 |
| GeneralSettingsSection.swift:88 | 会议记录缓存 | 对话记录缓存 |
| GeneralSettingsSection.swift:89 | …会议记录与录音文件… | …对话记录与录音文件… |
| GeneralSettingsSection.swift:98 | 会议保存路径（小标题） | 对话记录保存路径 |
| GeneralSettingsSection.swift:57 | …语音输入与会议记录同时生效 | …语音输入与对话记录同时生效 |

#### 第 4 组 · 历史页
| 位置 | 现在 | 改为 |
|---|---|---|
| HistoryTab.swift:432 | 搜索会议文件… | 搜索对话记录… |
| HistoryTab.swift:634 | 还没有会议记录 | 还没有对话记录 |

#### 第 5 组 · 菜单栏
| 位置 | 现在 | 改为 |
|---|---|---|
| MenuBarController.swift:121 | 会议录制中 | 记录中 |
| MenuBarController.swift:154 | 开始会议录制 | 开始记录 |
| MenuBarController.swift:156 | 停止会议录制（…） | 停止记录（…） |
| MenuBarController.swift:175 | 打开会议文件夹 | 打开对话记录文件夹 |

#### 第 6 组 · Onboarding / About
| 位置 | 现在 | 改为 |
|---|---|---|
| OnboardingView.swift:50 | …/ 会议摘要（可选） | …/ 对话摘要（可选） |
| OnboardingView.swift:53 | 「会议 → 摘要」 | 「对话记录 → 摘要」 |
| AboutTab.swift:33 | 语音识别（会议） | 语音识别（对话记录） |
| AboutTab.swift:35 | AI 摘要（会议） | AI 摘要（对话记录） |

#### 第 7 组 · 新生成文件的文件名前缀（旧文件不动）
| 位置 | 现在 | 改为 |
|---|---|---|
| MeetingService.swift:289 | 会议纪要_xxx.md | 对话记录_xxx.md |
| MeetingService.swift:300 | 会议录音_xxx.wav | 对话录音_xxx.wav |
| MeetingSummarizer.swift:45 | xxx_会议摘要.md | xxx_对话摘要.md |

文件名前缀改动安全性：重转写用日期正则（`yyyy-MM-dd_HH-mm-ss`）从文件名提取
开始时间，不依赖前缀；代码中也没有靠「会议录音_/会议纪要_」前缀做 md↔wav
配对的逻辑。新旧文件可共存。

#### 第 8 组 · 写进 markdown 的内文
| 位置 | 现在 | 改为 |
|---|---|---|
| MeetingService.swift:333 | `# 会议纪要` | `# 对话记录` |
| MeetingService.swift:590 | …本次会议仅录制麦克风 | …本次记录仅采集麦克风 |
| MeetingRetranscriber.swift:269 | `# 会议纪要（重转写…）` | `# 对话记录（重转写…）` |
| MeetingSummarizer.swift:50 | `# 会议摘要` | `# 对话摘要` |

#### 第 9 组 · LLM 错误返回（用户可见的那部分）
| 位置 | 现在 | 改为 |
|---|---|---|
| MeetingSummarizer.swift:201 | 会议记录内容为空，无法生成摘要 | 对话记录内容为空，无法生成摘要 |
| MeetingSummarizer.swift:205 | 请先配置会议摘要 AI 模型 | 请先配置对话摘要 AI 模型 |

LLM 提示词正文（MeetingSummarizer:73/135/152、Types.swift:505）保留「会议」措辞，
不在本次改动范围。

## 与其他功能的交集

- 功能 1（生成中徽章）的徽章文字「整理中 / 生成摘要中」不含「会议」字样，不受影响。
- 功能 2（记住最近任务类型）：`HistoryTab` 的 `Kind.meeting` rawValue 由
  「会议录音」改为「对话记录」（第 1 组），`Kind` 枚举 case 名 `meeting` 不变；
  功能 2 中 `lastHistoryKind` 存的是约定字符串 `"meeting"`，与显示用 rawValue
  无关，两者互不影响。

## 改动文件清单

VoiceSettingsSection、MainWindow、MeetingTab、HistoryTab、MeetingSettingsSection、
GeneralSettingsSection、MenuBarController、OnboardingView、AboutTab、Types、
MeetingService、MeetingRetranscriber、MeetingSummarizer。均为字符串字面量改动，
无结构、无符号、无协议变更。

## 测试与验收

- 语音页只剩大标题「语音输入」，无「语音设置」小标题；首张卡片间距正常。
- 全应用范围内已无用户可见的「会议」字样（清单第 10 组的保留项除外）：
  逐页核对 tab、菜单栏、设置页、历史页、关于页、Onboarding。
- 新建一次对话记录：生成的文件名为「对话记录_xxx.md」「对话录音_xxx.wav」，
  markdown 首行为 `# 对话记录`；摘要文件为「xxx_对话摘要.md」、首行 `# 对话摘要`。
- 旧的「会议纪要_xxx.md」文件仍能在历史页正常显示、打开、重转写。
- 构建并重启验证（命令见 CLAUDE.md「修改守则」第 6 条）。
