# 会议文件「生成中」徽章 — 设计文档

> 日期：2026-05-16
> 范围：History tab 会议录音列表 + MeetingService

## 背景与问题

用户结束会议录制（松手）后，会议纪要 markdown 文件在 History tab「会议录音」列表里
看着已经完整，但实际上后台还没处理完——`MeetingService` 仍要走两个阶段：

- `.finishing`：处理剩余音频、等待最后一段转写、把结束时间和时长写回 header
- `.summarizing`：调用 LLM 生成会议摘要并追加到文件（慢，可能数十秒）

关键事实：markdown 文件在 `initMarkdown()`（录制开始时）就已落盘，录制全程都能被
列表的目录扫描（`onAppear` + 每 3 秒 timer）扫到。所以「文件不出现」并非真问题——
真问题是上述两个后台阶段里文件看着完整、摘要却没写完，用户没有任何提示。

## 目标

录制结束后、`MeetingService.state` 处于 `.finishing` 或 `.summarizing` 期间，在
对应的会议文件卡片上显示一枚「生成中」徽章；阶段结束（`state → .idle`）后徽章自动消失。

## 非目标

- 不插入占位卡片（文件本就在磁盘上，扫描已能显示真实卡）
- 不改 `MeetingServiceProtocol` 协议
- 不动语音输入历史（`VoiceHistoryView`）
- 不覆盖 `.recording` / `.preparing` 阶段（用户明确要求仅「结束录制后」）

## 设计

### 1. 后端 — MeetingService 暴露处理中的文件

在 `MeetingService` 新增一个 published 属性：

```swift
/// 正在 finalize 的会议 markdown 文件绝对路径。
/// 仅当 state 为 .finishing / .summarizing 时非 nil；
/// History tab 用它给对应文件卡加「生成中」徽章。
@Published private(set) var processingMarkdownPath: String?
```

生命周期：

- `stop()` 中 `.recording → .finishing` 分支：`processingMarkdownPath = markdownFilePath`
  （此时 `markdownFilePath` 必为非 nil——`initMarkdown()` 已在录制开始时设置）
- `runRecording()` 末尾设 `state = .idle` 处：`processingMarkdownPath = nil`
- `cleanup()` 中设 `state = .idle` 处：`processingMarkdownPath = nil`

不复用现有 `markdownFilePath`：它是 private，且空会议路径下会被置 nil，语义与生命周期
都与「正在处理的文件」不一致。单独属性职责清晰。

空会议边界：`.finishing` 期间若 `transcribedSegmentCount == 0`，文件会被删除。徽章会
在文件卡上短暂闪现，下一次扫描（≤3s）发现文件已删则卡片整体消失，`state` 也已回 `.idle`。
可接受。

### 2. 前端 — MeetingHistoryView 给匹配卡加徽章

`MeetingHistoryView`（`HistoryTab.swift`）：

- 新增 `@EnvironmentObject private var meetingService: MeetingService`
  （`MeetingService` 已在环境中——`MeetingTab` 已以同样方式使用）
- `fileCard(_:)` 中判断是否显示徽章：

  ```
  显示徽章 ⇔ state 为 .finishing 或 .summarizing
            且 file.url.lastPathComponent == 处理中文件的文件名
  ```

  按**文件名**（`lastPathComponent`）比对，而非全路径——避开 `/private` 软链等路径
  归一化差异；会议文件名是时间戳命名、目录内唯一，足以精确匹配。

- 无需额外刷新逻辑：`state` 与 `processingMarkdownPath` 都是 `@Published`，
  `meetingService` 是 `@EnvironmentObject`，状态变化自动触发 `MeetingHistoryView` 重渲染；
  徽章在 `state → .idle` 时自动消失。现有的 3s timer 与 `.meetingFilesDidChange`
  通知继续负责文件内容/预览的刷新。

### 3. 徽章视觉

文件名右侧一枚小胶囊，位于 `fileCard` header 的 `HStack` 内（文件名 `Text` 之后、
`Spacer()` 之前）：

- 内容：`ProgressView()`（`.controlSize(.mini)` 转圈）+ 文字
- 文字按阶段区分（信息已现成，比笼统「生成中」更有用）：
  - `.finishing` → 「整理中」
  - `.summarizing` → 「生成摘要中」
- 配色：`theme.accent`，与卡片整体风格一致
- 胶囊：圆角背景 `theme.accent.opacity(0.12)`，小号字（~10pt）

## 改动清单

| 文件 | 改动 |
|------|------|
| `Backend/Meeting/MeetingService.swift` | 新增 `@Published private(set) var processingMarkdownPath`；在 `stop()`、`runRecording()` 末尾、`cleanup()` 三处维护其值（约 6 行） |
| `Frontend/Tabs/HistoryTab.swift` | `MeetingHistoryView` 新增 `meetingService` 环境对象；`fileCard` 加徽章判断与视图（约 15 行） |

无新文件、无协议变更、无 `Types.swift` 改动。

## 测试与验收

- 录一段有语音的会议，松手后切到 History → 会议录音：对应文件卡出现「整理中」→
  「生成摘要中」徽章（若开启会议 LLM），摘要完成后徽章消失。
- 未开启会议 LLM：仅短暂出现「整理中」，随即消失。
- 空会议（无语音）：徽章短暂闪现后文件卡整体消失。
- 其他历史文件卡不受影响，语音输入历史不受影响。
- 构建并重启验证（命令见 CLAUDE.md「修改守则」第 6 条）。
