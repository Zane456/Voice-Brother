# 对话记录 UX 改进 + 改名 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给会议历史文件加「生成中」徽章、让历史页记住最近完成的任务类型、把「会议」改名为「对话记录」并精简语音页标题。

**Architecture:** 三个独立小功能。功能 1 在 `MeetingService` 暴露处理中文件路径，`HistoryTab` 据此给文件卡加徽章。功能 2 在 `AppConfig` 持久化 `lastHistoryKind`，两个 Service 在任务完成点写入，`HistoryTab` 进入时读取。功能 3 是纯字符串字面量改名 + 删除一个 `SectionHeader`。全部不改代码符号、不改协议。

**Tech Stack:** Swift / SwiftUI / AppKit，macOS 14+ 应用。

**重要 — 无单元测试 target：** 本工程只有 `VoiceBubble` 一个 target，没有测试 target。每个任务的验证手段是 `xcodebuild build` 编译通过（exit 0）。功能行为的验收在最后一个任务里通过构建+重启+人工核对完成。

**构建命令（每个任务用）：**
```bash
cd "~/IDE project/Voice Bubble"
xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet
```
Expected: 命令退出码 0，无报错输出。

---

## Task 1: MeetingService 暴露处理中的 markdown 文件路径

**Files:**
- Modify: `VoiceBubble/Backend/Meeting/MeetingService.swift`

- [ ] **Step 1: 新增 `processingMarkdownPath` published 属性**

在 `prepareProgress` 属性声明之后（`// MARK: - Published State` 段内）加入：

```swift
    /// Absolute path of the markdown file for the meeting currently being
    /// finalized. Non-nil only while `state` is `.finishing` / `.summarizing`;
    /// the History tab uses it to badge that file card as "生成中".
    @Published private(set) var processingMarkdownPath: String?
```

紧贴在这段之后：

```swift
    /// Model load/download progress (0...1) while `state == .preparing`.
    /// nil once recording starts. Driven by `Qwen3ASRModel.fromPretrained`.
    @Published var prepareProgress: Double?
```

- [ ] **Step 2: 在 `stop()` 的 `.recording` 分支设置该路径**

把 `stop()` 中的 `.recording` 分支：

```swift
        case .recording:
            state = .finishing
            isRecording = false
            stopElapsedTimer()

            // Hide recording indicator
            RecordingOverlayPanel.shared.hide()
```

改为：

```swift
        case .recording:
            state = .finishing
            // Expose the in-progress markdown file so the History tab can
            // badge it as "生成中" until finalization + summarization finish.
            processingMarkdownPath = markdownFilePath
            isRecording = false
            stopElapsedTimer()

            // Hide recording indicator
            RecordingOverlayPanel.shared.hide()
```

- [ ] **Step 3: 在 `runRecording()` 末尾清空该路径**

把 `runRecording()` 末尾：

```swift
        // Re-enable single-key voice input now that finalization is complete
        voiceService?.keyboardListenerRef?.isMeetingActive = false

        // Update state
        state = .idle
```

改为：

```swift
        // Re-enable single-key voice input now that finalization is complete
        voiceService?.keyboardListenerRef?.isMeetingActive = false

        // Update state
        processingMarkdownPath = nil
        state = .idle
```

- [ ] **Step 4: 在 `cleanup()` 末尾清空该路径**

把 `cleanup()` 末尾：

```swift
        voiceService?.keyboardListenerRef?.isMeetingActive = false
        state = .idle
    }
```

改为：

```swift
        voiceService?.keyboardListenerRef?.isMeetingActive = false
        processingMarkdownPath = nil
        state = .idle
    }
```

- [ ] **Step 5: 构建验证**

Run:
```bash
cd "~/IDE project/Voice Bubble" && xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet
```
Expected: 退出码 0。

- [ ] **Step 6: Commit**

```bash
git add VoiceBubble/Backend/Meeting/MeetingService.swift
git commit -m "feat(meeting): expose processingMarkdownPath for in-progress badge"
```

---

## Task 2: HistoryTab 会议文件卡加「生成中」徽章

**Files:**
- Modify: `VoiceBubble/Frontend/Tabs/HistoryTab.swift`（`MeetingHistoryView`）

- [ ] **Step 1: 给 `MeetingHistoryView` 注入 `meetingService`**

在 `struct MeetingHistoryView: View {` 内，把：

```swift
struct MeetingHistoryView: View {
    @EnvironmentObject private var theme: ThemeManager
    let savePath: String
```

改为：

```swift
struct MeetingHistoryView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var meetingService: MeetingService
    let savePath: String
```

- [ ] **Step 2: 新增徽章判定与文案的辅助方法**

在 `MeetingHistoryView` 内，`fileCard(_:)` 方法的**正上方**加入：

```swift
    /// True when `file` is the markdown of the meeting currently being
    /// finalized — i.e. MeetingService is in `.finishing` / `.summarizing`
    /// and its processing file matches this card. Matched by filename
    /// (timestamped, unique per directory) to avoid path-normalization gaps.
    private func isProcessing(_ file: MarkdownFile) -> Bool {
        guard let activePath = meetingService.processingMarkdownPath else { return false }
        switch meetingService.state {
        case .finishing, .summarizing:
            return URL(fileURLWithPath: activePath).lastPathComponent
                == file.url.lastPathComponent
        default:
            return false
        }
    }

    /// Stage-specific badge text. Empty when not processing.
    private var processingBadgeText: String {
        switch meetingService.state {
        case .finishing: return "整理中"
        case .summarizing: return "生成摘要中"
        default: return ""
        }
    }

    private var processingBadge: some View {
        HStack(spacing: 4) {
            ProgressView()
                .controlSize(.mini)
                .tint(theme.accent)
            Text(processingBadgeText)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.accent)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(theme.accent.opacity(0.12)))
    }
```

- [ ] **Step 3: 在 `fileCard` 的 header `HStack` 中插入徽章**

把 `fileCard(_:)` 里的 header `HStack`：

```swift
            HStack {
                Image(systemName: "doc.text").font(.system(size: 13)).foregroundColor(theme.accentSecondary)
                Text(file.name).font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.textPrimary).lineLimit(1)
                Spacer()
                Text(formatDate(file.modifiedDate)).font(.system(size: 11)).foregroundColor(theme.textTertiary)
                Text(formatFileSize(file.fileSize)).font(.system(size: 11)).foregroundColor(theme.textTertiary)
            }
```

改为（在文件名 `Text` 之后、`Spacer()` 之前插入徽章）：

```swift
            HStack {
                Image(systemName: "doc.text").font(.system(size: 13)).foregroundColor(theme.accentSecondary)
                Text(file.name).font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.textPrimary).lineLimit(1)
                if isProcessing(file) {
                    processingBadge
                }
                Spacer()
                Text(formatDate(file.modifiedDate)).font(.system(size: 11)).foregroundColor(theme.textTertiary)
                Text(formatFileSize(file.fileSize)).font(.system(size: 11)).foregroundColor(theme.textTertiary)
            }
```

- [ ] **Step 4: 构建验证**

Run:
```bash
cd "~/IDE project/Voice Bubble" && xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet
```
Expected: 退出码 0。

- [ ] **Step 5: Commit**

```bash
git add VoiceBubble/Frontend/Tabs/HistoryTab.swift
git commit -m "feat(history): badge in-progress meeting file card"
```

---

## Task 3: AppConfig / ConfigManager 新增 `lastHistoryKind`

**Files:**
- Modify: `VoiceBubble/Shared/AppConfig.swift`
- Modify: `VoiceBubble/Backend/Services/ConfigManager.swift`

- [ ] **Step 1: AppConfig 新增 `@Published` 属性**

在 `AppConfig.swift` 中，把：

```swift
    @Published var migratedFromVoiceAura: Bool {
        didSet { scheduleSave() }
    }
```

改为（在其后追加新属性）：

```swift
    @Published var migratedFromVoiceAura: Bool {
        didSet { scheduleSave() }
    }
    /// Which History tab segment to show on open — tracks the most recently
    /// completed task. "voice" or "meeting".
    @Published var lastHistoryKind: String {
        didSet { scheduleSave() }
    }
```

- [ ] **Step 2: AppConfig 新增默认值**

在 `AppConfig.swift` 的 `// MARK: - Defaults` 段中，把：

```swift
    static let defaultOnboardingDone = false
    static let defaultMigrated = false
```

改为：

```swift
    static let defaultOnboardingDone = false
    static let defaultMigrated = false
    static let defaultLastHistoryKind = "voice"
```

- [ ] **Step 3: AppConfig `init()` 加载该值**

在 `init()` 中，把：

```swift
        self.migratedFromVoiceAura = Self.load("migratedFromVoiceAura", default: Self.defaultMigrated)
```

改为：

```swift
        self.migratedFromVoiceAura = Self.load("migratedFromVoiceAura", default: Self.defaultMigrated)
        self.lastHistoryKind = Self.load("lastHistoryKind", default: Self.defaultLastHistoryKind)
```

- [ ] **Step 4: AppConfig `performSave()` 写入该值**

在 `performSave()` 中，把：

```swift
        defaults.set(migratedFromVoiceAura, forKey: "migratedFromVoiceAura")
```

改为：

```swift
        defaults.set(migratedFromVoiceAura, forKey: "migratedFromVoiceAura")
        defaults.set(lastHistoryKind, forKey: "lastHistoryKind")
```

- [ ] **Step 5: ConfigManager 新增转发属性**

在 `ConfigManager.swift` 中，把：

```swift
    var onboardingDone: Bool {
        get { appConfig.onboardingDone }
        set { appConfig.onboardingDone = newValue }
    }
```

改为（在其后追加）：

```swift
    var onboardingDone: Bool {
        get { appConfig.onboardingDone }
        set { appConfig.onboardingDone = newValue }
    }
    var lastHistoryKind: String {
        get { appConfig.lastHistoryKind }
        set { appConfig.lastHistoryKind = newValue }
    }
```

- [ ] **Step 6: 构建验证**

Run:
```bash
cd "~/IDE project/Voice Bubble" && xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet
```
Expected: 退出码 0。

- [ ] **Step 7: Commit**

```bash
git add VoiceBubble/Shared/AppConfig.swift VoiceBubble/Backend/Services/ConfigManager.swift
git commit -m "feat(config): persist lastHistoryKind"
```

---

## Task 4: 任务完成点写入 `lastHistoryKind`

**Files:**
- Modify: `VoiceBubble/Backend/Voice/VoiceService.swift`（两处转写注入完成点）
- Modify: `VoiceBubble/Backend/Meeting/MeetingService.swift`（非空会议 finalize 后）

> `VoiceService` 与 `MeetingService` 都是 `@MainActor` 类，下面的赋值都在主 actor 上下文中，直接写即可。

- [ ] **Step 1: VoiceService — 第一处注入完成点**

在 `VoiceService.swift` 中找到第一处如下代码块（约 1188-1194 行，`TextInjector.typeText` 之后）：

```swift
        TextInjector.typeText(processedText, preserveClipboard: configManager.preserveClipboard)
        playEndSound()

        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let record = TranscriptionRecord(text: processedText, duration: duration)
        if !configManager.privacyMode {
            Task { await historyStore.insert(record) }
        }
    }
```

改为（在闭合 `}` 之前加一行）：

```swift
        TextInjector.typeText(processedText, preserveClipboard: configManager.preserveClipboard)
        playEndSound()

        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let record = TranscriptionRecord(text: processedText, duration: duration)
        if !configManager.privacyMode {
            Task { await historyStore.insert(record) }
        }
        // Voice input just completed — History tab opens on this segment next.
        configManager.lastHistoryKind = "voice"
    }
```

- [ ] **Step 2: VoiceService — 第二处注入完成点**

在 `VoiceService.swift` 中找到第二处如下代码块（约 1340-1348 行，注释 `// Record to history` 处）：

```swift
        // Inject text — no panel update; the overlay is already hidden, so
        // displaying the final text in it would have no visible effect.
        TextInjector.typeText(processedText, preserveClipboard: configManager.preserveClipboard)
        playEndSound()

        // Record to history
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let record = TranscriptionRecord(text: processedText, duration: duration)
        if !configManager.privacyMode {
            Task { await historyStore.insert(record) }
        }
    }
```

改为：

```swift
        // Inject text — no panel update; the overlay is already hidden, so
        // displaying the final text in it would have no visible effect.
        TextInjector.typeText(processedText, preserveClipboard: configManager.preserveClipboard)
        playEndSound()

        // Record to history
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let record = TranscriptionRecord(text: processedText, duration: duration)
        if !configManager.privacyMode {
            Task { await historyStore.insert(record) }
        }
        // Voice input just completed — History tab opens on this segment next.
        configManager.lastHistoryKind = "voice"
    }
```

- [ ] **Step 3: MeetingService — 非空会议 finalize 后**

在 `MeetingService.swift` 的 `runRecording()` 中，把：

```swift
        } else {
            finalizeMarkdown()
            NotificationCenter.default.post(name: .meetingFilesDidChange, object: nil)
        }
```

改为：

```swift
        } else {
            finalizeMarkdown()
            // A meeting with content just completed — History tab opens on
            // the meeting segment next.
            configManager.lastHistoryKind = "meeting"
            NotificationCenter.default.post(name: .meetingFilesDidChange, object: nil)
        }
```

> 注意：`cleanup()` 中也有一个结构相似的 `else { finalizeMarkdown() ... }` 块——**不要**改它（按 spec，只在 `runRecording()` 正常完成路径写入）。`runRecording()` 里的这个块紧跟在 `if isEmptyMeeting, let path = markdownFilePath { ... }` 之后，可据此区分。

- [ ] **Step 4: 构建验证**

Run:
```bash
cd "~/IDE project/Voice Bubble" && xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet
```
Expected: 退出码 0。

- [ ] **Step 5: Commit**

```bash
git add VoiceBubble/Backend/Voice/VoiceService.swift VoiceBubble/Backend/Meeting/MeetingService.swift
git commit -m "feat(history): record lastHistoryKind on task completion"
```

---

## Task 5: HistoryTab 进入时按 `lastHistoryKind` 定位分段

**Files:**
- Modify: `VoiceBubble/Frontend/Tabs/HistoryTab.swift`（`HistoryTab` 结构体）

- [ ] **Step 1: 新增初始化守护标志**

在 `struct HistoryTab: View {` 内，把：

```swift
    @State private var selectedKind: Kind = .voice
```

改为：

```swift
    @State private var selectedKind: Kind = .voice
    /// Guards the one-time `selectedKind` sync from `lastHistoryKind` so a
    /// manual segment switch isn't overridden on every re-appear.
    @State private var didInitKind = false
```

- [ ] **Step 2: 在 body 外层 VStack 加 `.onAppear` 读取 config**

`HistoryTab` 的 `body` 最外层是 `VStack(alignment: .leading, spacing: 0) { ... }`，结尾为 `.frame(maxWidth: .infinity, maxHeight: .infinity)`。把：

```swift
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

（即 `HistoryTab` body 的收尾——注意这是 `HistoryTab` 而非 `VoiceHistoryView`/`MeetingHistoryView` 的 body）改为：

```swift
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // One-time sync: open on whichever segment the most recently
            // completed task belongs to. Manual switches afterwards stand.
            guard !didInitKind else { return }
            selectedKind = configManager.lastHistoryKind == "meeting" ? .meeting : .voice
            didInitKind = true
        }
    }
}
```

> 定位方法：`HistoryTab` 的 body 是文件中第一个 `var body`，其 `VStack` 内含 `Picker` 和对 `VoiceHistoryView()`/`MeetingHistoryView(...)` 的 `switch`。改的是这个 body 的收尾，不要改到后面两个子视图。

- [ ] **Step 3: 构建验证**

Run:
```bash
cd "~/IDE project/Voice Bubble" && xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet
```
Expected: 退出码 0。

- [ ] **Step 4: Commit**

```bash
git add VoiceBubble/Frontend/Tabs/HistoryTab.swift
git commit -m "feat(history): open on last completed task's segment"
```

---

## Task 6: 删除语音设置页冗余小标题

**Files:**
- Modify: `VoiceBubble/Frontend/Tabs/Sections/VoiceSettingsSection.swift`

- [ ] **Step 1: 删除 `SectionHeader(title: "语音设置")`**

把 `VoiceSettingsSection` 的 `body` 开头：

```swift
        VStack(alignment: .leading, spacing: 16) {
            // 输入行为 toggles (语气词过滤/空格重定位/剪贴板保护) all live in
            // the 通用 tab now — gathered in one place.

            SectionHeader(title: "语音设置")

            // Trigger Key
            triggerKeyCard
```

改为（删掉 `SectionHeader` 行及其上方空行）：

```swift
        VStack(alignment: .leading, spacing: 16) {
            // 输入行为 toggles (语气词过滤/空格重定位/剪贴板保护) all live in
            // the 通用 tab now — gathered in one place.

            // Trigger Key
            triggerKeyCard
```

- [ ] **Step 2: 构建验证**

Run:
```bash
cd "~/IDE project/Voice Bubble" && xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet
```
Expected: 退出码 0。

- [ ] **Step 3: Commit**

```bash
git add VoiceBubble/Frontend/Tabs/Sections/VoiceSettingsSection.swift
git commit -m "refactor(voice): drop redundant 语音设置 section header"
```

---

## Task 7: 「会议」→「对话记录」全量改名

**Files:**
- Modify: `VoiceBubble/Frontend/MainWindow.swift`
- Modify: `VoiceBubble/Frontend/MenuBarController.swift`
- Modify: `VoiceBubble/Frontend/OnboardingView.swift`
- Modify: `VoiceBubble/Frontend/Tabs/MeetingTab.swift`
- Modify: `VoiceBubble/Frontend/Tabs/HistoryTab.swift`
- Modify: `VoiceBubble/Frontend/Tabs/AboutTab.swift`
- Modify: `VoiceBubble/Frontend/Tabs/Sections/MeetingSettingsSection.swift`
- Modify: `VoiceBubble/Frontend/Tabs/Sections/GeneralSettingsSection.swift`
- Modify: `VoiceBubble/Shared/Types.swift`
- Modify: `VoiceBubble/Backend/Meeting/MeetingService.swift`
- Modify: `VoiceBubble/Backend/Meeting/MeetingRetranscriber.swift`
- Modify: `VoiceBubble/Backend/Meeting/MeetingSummarizer.swift`

> 全部是字符串字面量替换。每条用 Edit 工具：`old_string` 取下表「现在」列（必要时带足上下文保证唯一），`new_string` 取「改为」列。**不改任何 Swift 符号名**（`meeting` case 名、`MeetingService` 等保持原样）。

- [ ] **Step 1: MainWindow.swift**

| 现在 | 改为 |
|---|---|
| `case meeting = "会议"` | `case meeting = "对话记录"` |
| `case .meeting: return "会议纪要"` | `case .meeting: return "对话记录"` |

- [ ] **Step 2: MeetingTab.swift**

| 现在 | 改为 |
|---|---|
| `Text("会议")` | `Text("对话记录")` |
| `Text(isRecording ? "停止会议" : "开始会议")` | `Text(isRecording ? "停止记录" : "开始记录")` |
| `Text("打开会议记录文件夹")` | `Text("打开对话记录文件夹")` |
| `return "正在加载会议模型… \(Int(p * 100))%"` | `return "正在加载识别模型… \(Int(p * 100))%"` |
| `return "正在加载会议模型…"` | `return "正在加载识别模型…"` |
| `default: return "准备录制会议"` | `default: return "准备开始记录"` |
| `+ Text(" 即可启动会议")` | `+ Text(" 即可开始记录")` |

- [ ] **Step 3: HistoryTab.swift**

| 现在 | 改为 |
|---|---|
| `case meeting = "会议录音"` | `case meeting = "对话记录"` |
| `TextField("搜索会议文件...", text: $searchText)` | `TextField("搜索对话记录...", text: $searchText)` |
| `Text("还没有会议记录")` | `Text("还没有对话记录")` |

> `case meeting = "会议录音"` 在 HistoryTab.swift 中全文件唯一（它属于文件顶部的 `HistoryTab.Kind` 枚举），直接替换即可。`meeting` 这个 case 名不变，只改 rawValue。

- [ ] **Step 4: MeetingSettingsSection.swift**

| 现在 | 改为 |
|---|---|
| `SectionHeader(title: "会议设置")` | `SectionHeader(title: "对话记录设置")` |
| `Text("会议固定使用本地 Qwen 模型，与语音输入相互独立。首次使用某个模型会自动下载。")` | `Text("对话记录固定使用本地 Qwen 模型，与语音输入相互独立。首次使用某个模型会自动下载。")` |
| `Text("录制结束后自动生成会议摘要")` | `Text("录制结束后自动生成对话摘要")` |
| `Text("会议摘要提示词")` | `Text("对话摘要提示词")` |
| `Text("点击「应用模板」选择一个会议类型，或自定义后点「存为模板」保存。")` | `Text("点击「应用模板」选择一个对话类型，或自定义后点「存为模板」保存。")` |
| `Text("保存为会议摘要模板")` | `Text("保存为对话摘要模板")` |

- [ ] **Step 5: GeneralSettingsSection.swift**

| 现在 | 改为 |
|---|---|
| `retentionRow(title: "会议记录缓存",` | `retentionRow(title: "对话记录缓存",` |
| `subtitle: "超过该时长的会议记录与录音文件会自动清理",` | `subtitle: "超过该时长的对话记录与录音文件会自动清理",` |
| `SectionHeader(title: "会议保存路径")` | `SectionHeader(title: "对话记录保存路径")` |
| `subtitle: "自动删除「嗯」「啊」「那个」等口头禅 · 语音输入与会议记录同时生效",` | `subtitle: "自动删除「嗯」「啊」「那个」等口头禅 · 语音输入与对话记录同时生效",` |

- [ ] **Step 6: MenuBarController.swift**

| 现在 | 改为 |
|---|---|
| `return (StatusBarIcon.recording(), .systemRed, "会议录制中")` | `return (StatusBarIcon.recording(), .systemRed, "记录中")` |
| `case .idle, .error: meetingTitle = "开始会议录制"` | `case .idle, .error: meetingTitle = "开始记录"` |
| `case .recording: meetingTitle = "停止会议录制（\(formatElapsed(meetingService.elapsedSeconds))）"` | `case .recording: meetingTitle = "停止记录（\(formatElapsed(meetingService.elapsedSeconds))）"` |
| `let openFolderItem = NSMenuItem(title: "打开会议文件夹", action: #selector(openMeetingFolder), keyEquivalent: "")` | `let openFolderItem = NSMenuItem(title: "打开对话记录文件夹", action: #selector(openMeetingFolder), keyEquivalent: "")` |

- [ ] **Step 7: OnboardingView.swift**

| 现在 | 改为 |
|---|---|
| `Text("AI 云端润色 / 会议摘要（可选）")` | `Text("AI 云端润色 / 对话摘要（可选）")` |
| `Text("如需更强的文本润色或会议摘要，可在「语音 → AI 大模型」或「会议 → 摘要」中填入你自己的 API Key（推荐 OpenRouter，一个 key 通用多家模型）。API Key 保存在系统 Keychain，不会随应用分发。")` | `Text("如需更强的文本润色或对话摘要，可在「语音 → AI 大模型」或「对话记录 → 摘要」中填入你自己的 API Key（推荐 OpenRouter，一个 key 通用多家模型）。API Key 保存在系统 Keychain，不会随应用分发。")` |

- [ ] **Step 8: AboutTab.swift**

| 现在 | 改为 |
|---|---|
| `dataFlowRow(label: "语音识别（会议）", state: meetingASRState)` | `dataFlowRow(label: "语音识别（对话记录）", state: meetingASRState)` |
| `dataFlowRow(label: "AI 摘要（会议）", state: meetingSummaryState)` | `dataFlowRow(label: "AI 摘要（对话记录）", state: meetingSummaryState)` |

- [ ] **Step 9: Types.swift**

| 现在 | 改为 |
|---|---|
| `case .preparing: return "加载会议模型..."` | `case .preparing: return "加载识别模型..."` |
| `case .summarizing: return "生成会议摘要..."` | `case .summarizing: return "生成对话摘要..."` |

> Types.swift:505 的 LLM 提示词（`你是会议纪要整理助手...`）**不改**。

- [ ] **Step 10: MeetingService.swift**

| 现在 | 改为 |
|---|---|
| `state = .error("会议录制失败: \(error.localizedDescription)")` | `state = .error("记录失败: \(error.localizedDescription)")` |
| `let filename = "会议纪要_\(ts).md"` | `let filename = "对话记录_\(ts).md"` |
| `let audioFilename = "会议录音_\(ts).wav"` | `let audioFilename = "对话录音_\(ts).wav"` |
| `writeToFile("> ⚠️ 系统音频未能采集（可能未授予屏幕录制权限），本次会议仅录制麦克风。\n\n")` | `writeToFile("> ⚠️ 系统音频未能采集（可能未授予屏幕录制权限），本次记录仅采集麦克风。\n\n")` |

另外把 `initMarkdown()` 里多行字符串 header 的首行 `# 会议纪要` 改为 `# 对话记录`。该多行字面量为：

```swift
        let header = """
        # 会议纪要

        - 日期：\(dateStr)
```

改为：

```swift
        let header = """
        # 对话记录

        - 日期：\(dateStr)
```

- [ ] **Step 11: MeetingRetranscriber.swift**

| 现在 | 改为 |
|---|---|
| `lines.append("# 会议纪要（重转写：\(language ?? "Auto")）")` | `lines.append("# 对话记录（重转写：\(language ?? "Auto")）")` |

- [ ] **Step 12: MeetingSummarizer.swift**

| 现在 | 改为 |
|---|---|
| `let summaryURL = transcriptURL.deletingLastPathComponent().appendingPathComponent(baseName + "_会议摘要.md")` | `let summaryURL = transcriptURL.deletingLastPathComponent().appendingPathComponent(baseName + "_对话摘要.md")` |
| `return "会议记录内容为空，无法生成摘要"` | `return "对话记录内容为空，无法生成摘要"` |
| `return "请先配置会议摘要 AI 模型"` | `return "请先配置对话摘要 AI 模型"` |

`MeetingSummarizer.swift` 第 50 行的 `# 会议摘要` 改为 `# 对话摘要`。该处上下文为摘要 markdown 的标题行，把字面量中的 `# 会议摘要` 改为 `# 对话摘要`。

> MeetingSummarizer.swift:73/135/152 的 LLM 提示词正文（`你是会议纪要整理助手...`、`这是会议转写的第...`、`以下是同一会议分段摘要...`）**不改**。

- [ ] **Step 13: 核对无遗漏**

Run:
```bash
cd "~/IDE project/Voice Bubble" && grep -rn "会议" VoiceBubble/ --include="*.swift"
```
Expected: 剩余命中应**只**包含以下「保留项」——
- `Types.swift:505`、`MeetingSummarizer.swift` 的 LLM 提示词正文（73/135/152 附近）
- `GeneralSettingsSection.swift` 隐私模式说明里的「内部会议」
- 各 `.swift` 文件里的代码注释
- `MeetingRetranscribeLauncher.swift:45` 注释里的示例文件名

若出现上述之外的用户可见字符串命中，补改。

- [ ] **Step 14: 构建验证**

Run:
```bash
cd "~/IDE project/Voice Bubble" && xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet
```
Expected: 退出码 0。

- [ ] **Step 15: Commit**

```bash
git add VoiceBubble/
git commit -m "refactor(ui): rename 会议 to 对话记录 across user-facing strings"
```

---

## Task 8: 整体构建、重启与人工验收

**Files:** 无（仅构建与运行验证）

- [ ] **Step 1: 构建、关闭旧实例、启动新构建**

```bash
cd "~/IDE project/Voice Bubble"
xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet
pkill -x "VoiceBubble" 2>/dev/null || true
open "~/Library/Developer/Xcode/DerivedData/VoiceBubble-arbvxvbxxsnfymbulsnszkqkgdon/Build/Products/Debug/VoiceBubble.app"
```
Expected: 构建退出码 0，应用启动。

- [ ] **Step 2: 人工验收 — 功能 1（生成中徽章）**

录一段有语音的对话记录，松手后切到 历史 → 对话记录：
- 对应文件卡出现「整理中」徽章（带转圈）；若开启了对话 LLM，随后变「生成摘要中」；摘要完成后徽章消失。
- 空记录（无语音）：徽章短暂闪现后文件卡整体消失。

- [ ] **Step 3: 人工验收 — 功能 2（记住最近任务类型）**

- 完成一次语音输入 → 进入 历史 tab：停在「语音输入」。
- 完成一次对话记录（有语音）→ 进入 历史 tab：停在「对话记录」。
- 重启 app 后进入 历史 tab：仍停在重启前最近完成任务的类型。
- 在历史页手动切到另一分段、切走再回来：仍按最近完成任务定位。

- [ ] **Step 4: 人工验收 — 功能 3（改名 + 语音页标题）**

- 语音页只剩大标题「语音输入」，无「语音设置」小标题，首张卡片间距正常。
- 逐页核对已无用户可见的「会议」字样：tab 名、菜单栏、设置页、历史页、关于页、Onboarding。
- 新建一次对话记录：文件名为「对话记录_xxx.md」「对话录音_xxx.wav」，markdown 首行 `# 对话记录`；摘要文件「xxx_对话摘要.md」、首行 `# 对话摘要`。
- 旧的「会议纪要_xxx.md」文件仍能在历史页正常显示、打开、重转写。

- [ ] **Step 5: 验收说明**

若以上任一项不符，回到对应 Task 修正后重新执行本任务。全部通过即实现完成。

---

## 实现完成后

所有任务完成、Task 8 验收通过后，使用 `superpowers:finishing-a-development-branch` skill 处理分支合并/PR。
