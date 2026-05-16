# History tab 记住最近任务类型 — 设计文档

> 日期：2026-05-16
> 范围：History tab 分段切换 + AppConfig/ConfigManager + VoiceService + MeetingService

## 背景与问题

History tab 顶部有「语音输入 / 会议录音」分段切换。当前 `MeetingHistoryView` 所在的
`HistoryTab` 用本地 `@State private var selectedKind: Kind = .voice`——固定默认「语音输入」，
切走再回来、app 重启都会重置。

用户希望：进入历史页时，自动停在**最近一次完成的任务**所对应的分段。若上一个完成的
任务是会议录制，就停在「会议录音」；若是语音输入，就停在「语音输入」。且跨 app 重启记忆。

## 目标

- 记录"最近完成的任务类型"（语音输入 / 会议录音），跨 app 重启持久化
- 进入 History tab 时，分段切换默认停在该类型对应的界面

## 非目标

- 不记录用户在历史页内的**手动**切换（用户明确选「最近完成的任务」而非「最近手动选的 tab」）
- History tab 已打开期间不做实时跟随切换（仅进入页面时应用一次）
- 不改 `MeetingServiceProtocol` / `VoiceServiceProtocol` 协议

## 方案选择

**方案 A — 显式持久化标志（采用）**：AppConfig 新增 `lastHistoryKind` 字符串，
两个 Service 在任务完成点写入，HistoryTab 进入时读取。

**方案 B — 时间戳推断（否决）**：进入时比较最新语音记录时间戳与最新会议文件 mtime。
否决原因：隐私模式下语音任务不入库会漏判；删除最新条目会改变推断结果——不严格等于
"最近完成的任务"。

采用 A：精确对应"最近完成的任务"语义，不受条目删除影响，跨重启天然记忆。

## 设计

### 1. AppConfig / ConfigManager 新增持久化属性

`AppConfig` 新增：

```swift
@Published var lastHistoryKind: String {
    didSet { scheduleSave() }
}
```

- 默认值 `"voice"`
- 取值约定：`"voice"` | `"meeting"`
- 按现有套路接入 UserDefaults 的 load 与 save（新增一个 key，如 `lastHistoryKind`）

`ConfigManager` 加一个转发计算属性（与现有所有属性一致）：

```swift
var lastHistoryKind: String {
    get { appConfig.lastHistoryKind }
    set { appConfig.lastHistoryKind = newValue }
}
```

### 2. 写入点

**VoiceService** —— 语音转写注入完成处写 `"voice"`。VoiceService 有两处转写注入完成
路径，各自在 `historyStore.insert(record)` 附近，两处都写：

```swift
configManager.lastHistoryKind = "voice"
```

隐私模式（`privacyMode`）下语音记录虽不入库，但任务确实发生了，仍写标志。

**MeetingService** —— `runRecording()` 末尾**非空会议**分支，`finalizeMarkdown()` 之后写：

```swift
configManager.lastHistoryKind = "meeting"
```

空会议分支（`isEmptyMeeting`）不写——没有产生任务成果。

### 3. HistoryTab 读取

`HistoryTab` 的 `selectedKind` 仍是 `@State`，首次进入时从 config 取初值：

- 新增一个 `@State private var didInitKind = false` 守护标志
- `.onAppear` 中：若 `!didInitKind`，把 `selectedKind` 设为
  `configManager.lastHistoryKind == "meeting" ? .meeting : .voice`，并置 `didInitKind = true`
- 之后用户在历史页手动切换分段**不回写** config——只有任务完成才更新 `lastHistoryKind`

首帧会短暂显示默认 `.voice` 再切换，闪烁一帧，可忽略。

`Kind` 枚举保持 `HistoryTab` 私有，不外泄；config 里存原始字符串，HistoryTab 内部做
字符串 ↔ `Kind` 映射。

## 改动清单

| 文件 | 改动 |
|------|------|
| `Shared/AppConfig.swift` | 新增 `@Published var lastHistoryKind`，接入 UserDefaults load/save（约 5 行） |
| `Backend/Services/ConfigManager.swift` | 新增 `lastHistoryKind` 转发属性（约 4 行） |
| `Backend/Voice/VoiceService.swift` | 两处转写注入完成点各写一行 `lastHistoryKind = "voice"`（2 行） |
| `Backend/Meeting/MeetingService.swift` | 非空会议 finalize 后写 `lastHistoryKind = "meeting"`（1 行） |
| `Frontend/Tabs/HistoryTab.swift` | `HistoryTab` 新增 `didInitKind` 守护 + `.onAppear` 读取 config 设 `selectedKind`（约 6 行） |

无协议变更、无 `Types.swift` 改动、无新文件。

## 测试与验收

- 完成一次语音输入 → 进入 History tab：停在「语音输入」
- 完成一次会议录制（有语音）→ 进入 History tab：停在「会议录音」
- 空会议（无语音）：不改变 `lastHistoryKind`，仍停在上一次的类型
- 重启 app 后进入 History tab：仍停在重启前最近完成任务的类型
- 在历史页内手动切到另一分段、切走再回来：仍按最近完成任务定位（手动切换不持久化）
- 构建并重启验证（命令见 CLAUDE.md「修改守则」第 6 条）。
