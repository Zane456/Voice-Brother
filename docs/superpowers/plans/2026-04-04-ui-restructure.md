# UI Restructure: Sidebar & Tab Reorganization

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the 4-tab sidebar (通用/语音/记录/关于), make 语音 and 记录 parallel with `[设置|历史]` segmented control, add status cards with usage instructions at top of each.

**Architecture:** MainWindow sidebar stays 4 items with new names. SettingsTab becomes GeneralTab (general-only). VoiceTab gains segmented `[设置|历史]` with VoiceSettingsSection integrated. MeetingTab becomes RecordTab with same parallel structure. AboutTab gains usage instructions section.

**Tech Stack:** SwiftUI, existing Glassmorphism components, existing Section components

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `Frontend/MainWindow.swift` | Modify | Update sidebar tab names, icons, struct references |
| `Frontend/Tabs/SettingsTab.swift` | Modify | Strip to GeneralTab (remove voice/meeting sections) |
| `Frontend/Tabs/VoiceTab.swift` | Rewrite | Add status card + segmented `[设置|历史]`, integrate VoiceSettingsSection |
| `Frontend/Tabs/MeetingTab.swift` | Rewrite | Become RecordTab: status card with controls + segmented `[设置|历史]`, integrate MeetingSettingsSection |
| `Frontend/Tabs/AboutTab.swift` | Modify | Add usage instructions section |
| `Frontend/Tabs/Sections/GeneralSettingsSection.swift` | No change | Used as-is by GeneralTab |
| `Frontend/Tabs/Sections/VoiceSettingsSection.swift` | Minor modify | Remove `@Binding var pendingRestart`, manage restart state internally |
| `Frontend/Tabs/Sections/MeetingSettingsSection.swift` | No change | Used as-is by RecordTab |

---

### Task 1: Update MainWindow Sidebar

**Files:**
- Modify: `VoiceBubble/Frontend/MainWindow.swift`

- [ ] **Step 1: Update AppTab enum**

Change the enum in `MainWindow.swift:11-25`:

```swift
private enum AppTab: String, CaseIterable {
    case general = "通用"
    case voice = "语音"
    case recording = "记录"
    case about = "关于"

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .voice: return "waveform"
        case .recording: return "record.circle"
        case .about: return "info.circle"
        }
    }
}
```

- [ ] **Step 2: Update switch statement**

Change `MainWindow.swift:39-49` to match new case names:

```swift
switch selectedTab {
case .general:
    GeneralTab()
case .voice:
    VoiceTab()
case .recording:
    RecordTab()
case .about:
    AboutTab()
}
```

Also update `selectedTab` default to `.general`:
```swift
@State private var selectedTab: AppTab = .general
```

- [ ] **Step 3: Build verify**

Run: `cd "/Users/zhangzheng/IDE project/Voice Bubble" && xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet 2>&1 | tail -5`

Expected: Build errors because `GeneralTab` and `RecordTab` don't exist yet. This is expected — proceed to Task 2.

---

### Task 2: Rename SettingsTab to GeneralTab

**Files:**
- Modify: `VoiceBubble/Frontend/Tabs/SettingsTab.swift`

- [ ] **Step 1: Restructure SettingsTab**

Rewrite `SettingsTab.swift` to become `GeneralTab`. Remove `VoiceSettingsSection` and `MeetingSettingsSection` references. Keep `PermissionWarningSection` and `GeneralSettingsSection`.

The new `GeneralTab` struct:

```swift
import SwiftUI

struct GeneralTab: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var voiceService: VoiceService
    @EnvironmentObject private var permissionManager: PermissionManager

    @State private var pendingRestart = false
    @State private var permissionRefreshTimer: Timer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Permission Warning
                if !permissionManager.status.allGranted {
                    PermissionWarningSection()
                }

                // General Settings
                GeneralSettingsSection(pendingRestart: $pendingRestart)

                // Self-Learning
                selfLearningSection

                // Restart Notice
                if pendingRestart {
                    restartNotice
                }
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            startPermissionRefreshTimer()
        }
        .onDisappear {
            permissionRefreshTimer?.invalidate()
            permissionRefreshTimer = nil
        }
        .onChange(of: permissionManager.status) { newStatus in
            if newStatus.allGranted, case .error = voiceService.state {
                voiceService.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    voiceService.start()
                }
            }
        }
    }

    // MARK: - Self-Learning Section

    private var selfLearningSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "自学习")

            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动学习替换规则")
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "2C3E6B"))

                        Text("当你手动修正语音输入的文字后，系统会自动记住修正内容，下次自动替换")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "8AA0BE"))
                    }

                    Spacer()

                    Toggle("", isOn: $configManager.selfLearningEnabled)
                        .toggleStyle(CustomToggleStyle())
                        .labelsHidden()
                }

                if configManager.selfLearningEnabled {
                    Divider()
                        .foregroundColor(Color(hex: "8AA0BE").opacity(0.3))

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("学习阈值")
                                .font(.system(size: 14))
                                .foregroundColor(Color(hex: "2C3E6B"))

                                Text("同一修正出现达到此次数后，自动添加为替换规则")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color(hex: "8AA0BE"))
                        }

                        Spacer()

                        Stepper(
                            "\(configManager.selfLearningThreshold) 次",
                            value: $configManager.selfLearningThreshold,
                            in: 1...10
                        )
                        .font(.system(size: 13))
                    }
                }
            }
            .padding(16)
            .glassCard()
        }
    }

    // MARK: - Restart Notice

    private var restartNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(Color(hex: "C89828"))

            Text("需要重启服务生效")
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "5A7098"))

            Spacer()

            Button {
                voiceService.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    voiceService.start()
                }
                pendingRestart = false
            } label: {
                Text("立即重启")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color(hex: "7B8CF5"))
                    .cornerRadius(11)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .glassCard()
    }

    private func startPermissionRefreshTimer() {
        permissionRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            permissionManager.recheckAll()
        }
    }
}
```

Note: Keep the file named `SettingsTab.swift` — only the struct name changes to `GeneralTab`. This avoids Xcode project file edits.

- [ ] **Step 2: Build verify**

Run: `cd "/Users/zhangzheng/IDE project/Voice Bubble" && xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet 2>&1 | tail -5`

Expected: Errors about missing `RecordTab` — that's fine. No errors about `GeneralTab` should appear.

---

### Task 3: Restructure VoiceTab with Segmented Control

**Files:**
- Rewrite: `VoiceBubble/Frontend/Tabs/VoiceTab.swift`
- Minor modify: `VoiceBubble/Frontend/Tabs/Sections/VoiceSettingsSection.swift` (remove `@Binding var pendingRestart`, add internal state)

This is the largest task. VoiceTab currently contains only history. It needs to become a two-panel view with `[设置 | 历史]` segmented control.

- [ ] **Step 1: Modify VoiceSettingsSection to remove pendingRestart binding**

In `VoiceSettingsSection.swift`, remove the `@Binding var pendingRestart: Bool` property and the `restartNotice` view. The restart logic will be handled at the VoiceTab level instead.

Changes to `VoiceSettingsSection.swift`:
1. Remove `@Binding var pendingRestart: Bool` (line 9)
2. Remove `private var restartNotice` (lines 898-916)
3. Remove the `if hasUnsavedChanges { restartNotice }` in body (lines 40-42)
4. Remove `checkPendingRestart()` method (lines 969-973) — or keep it but emit a notification
5. Actually, simplest approach: replace `@Binding var pendingRestart` with a closure callback `var onModelChange: (() -> Void)? = nil` and call it when model changes. But since VoiceTab will own the VoiceSettingsSection, it can just observe configManager changes directly.

Simplest approach: Just remove `@Binding var pendingRestart` entirely. VoiceTab will add its own restart notice by observing `voiceService.state`.

In `VoiceSettingsSection.swift`:
- Remove line 9: `@Binding var pendingRestart: Bool`
- Remove lines 40-42: `if hasUnsavedChanges { restartNotice }`
- Remove lines 898-916: `private var restartNotice`
- Remove lines 969-973: `private func checkPendingRestart()`
- Remove the two calls to `checkPendingRestart()` (in trigger key onChange and at end of file)

- [ ] **Step 2: Rewrite VoiceTab.swift**

Rewrite the entire `VoiceTab.swift`. The structure:

```
VStack
├── Status Card (service state + usage instructions) - always visible
├── Segmented Control [设置 | 历史]
└── Content area (switches between settings and history)
    ├── Settings: VoiceSettingsSection wrapped in ScrollView
    └── History: existing history code (search, stats, records, export)
```

Key points:
- Default sub-tab: `.history`
- Status card shows: voice service state indicator, current model name, usage instructions
- Settings sub-view wraps `VoiceSettingsSection()` in a `ScrollView`
- History sub-view is the existing VoiceTab content (search, stats, date-grouped records, export)
- `pendingRestart` state and restart notice are managed at VoiceTab level
- History `@State` properties (records, searchText, etc.) persist across tab switches because VoiceTab owns them

Full rewrite of `VoiceTab.swift`:

```swift
import SwiftUI

struct VoiceTab: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var voiceService: VoiceService

    private let historyStore = HistoryStore()

    // Sub-tab selection - default to history
    @State private var selectedSubTab: SubTab = .history

    // History state
    @State private var records: [TranscriptionRecord] = []
    @State private var hasMore = true
    @State private var isLoadingMore = false
    @State private var searchText = ""
    @State private var copiedId: UUID?
    @State private var statistics: HistoryStore.Statistics?
    @State private var showClearConfirm = false
    @State private var showExportPopover = false

    // Restart state
    @State private var pendingRestart = false

    private enum SubTab: String, CaseIterable {
        case settings = "设置"
        case history = "历史"
    }

    private static let pageSize = 20

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status Card
            statusCard
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, 16)

            // Segmented Control
            Picker("", selection: $selectedSubTab) {
                ForEach(SubTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 32)
            .padding(.bottom, 16)

            // Restart Notice (below segmented, above content)
            if pendingRestart {
                restartNotice
                    .padding(.horizontal, 32)
                    .padding(.bottom, 16)
            }

            // Content
            Group {
                switch selectedSubTab {
                case .settings:
                    settingsView
                case .history:
                    historyView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await loadRecords()
            await loadStatistics()
        }
        .onReceive(NotificationCenter.default.publisher(for: .historyStoreDidChange)) { _ in
            Task {
                await loadRecords()
                await loadStatistics()
            }
        }
        .alert("确认清空", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                Task {
                    await historyStore.deleteAll()
                    records.removeAll()
                    statistics = nil
                }
            }
        } message: {
            Text("将清空所有历史记录，此操作不可撤销。")
        }
    }

    // MARK: - Status Card

    private var statusCard: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(voiceService.state.isActive ? Color(hex: "4ECDC4") : (voiceService.state == .ready ? Color.green : Color(hex: "C8D8EA")))
                .frame(width: 10, height: 10)

            Text(voiceService.state.displayText)
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "2C3E6B"))

            Spacer()

            // Usage instructions
            HStack(spacing: 6) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 12))
                Text("按住 \(triggerKeyDisplayName) 说话，松开自动输入文字")
                    .font(.system(size: 12))
            }
            .foregroundColor(Color(hex: "5A7098"))
        }
        .padding(16)
        .glassCard()
    }

    private var triggerKeyDisplayName: String {
        TriggerKey(rawValue: configManager.triggerKey)?.displayName ?? "右 ⌘"
    }

    // MARK: - Settings View

    private var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VoiceSettingsSection()
            }
            .padding(32)
        }
    }

    // MARK: - Restart Notice

    private var restartNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(Color(hex: "C89828"))

            Text("需要重启服务生效")
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "5A7098"))

            Spacer()

            Button {
                voiceService.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    voiceService.start()
                }
                pendingRestart = false
            } label: {
                Text("立即重启")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color(hex: "7B8CF5"))
                    .cornerRadius(11)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .glassCard()
    }

    // MARK: - History View
    // (Move all existing history-related code here as computed properties)

    private var historyView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ... (existing history content from current VoiceTab)
            // Header, Statistics, Search, Record list, etc.
            // EXACT same code as current VoiceTab body, but wrapped as a computed property
        }
    }

    // ... (all existing history helper methods: loadRecords, loadMore, searchBar,
    //      statisticsSection, dateGroup, groupedRecords, recordCard, export, etc.)
}
```

**IMPORTANT:** The history view code should be moved from the current `body` into `historyView` computed property with minimal changes. All existing `@State` properties, data loading, search, stats, export, date grouping, record cards, empty states, and helpers remain exactly as-is. Only the structural wrapper changes.

- [ ] **Step 3: Build verify**

Run: `cd "/Users/zhangzheng/IDE project/Voice Bubble" && xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet 2>&1 | tail -5`

Expected: Only `RecordTab` not found error. All other compilation should pass.

---

### Task 4: Create RecordTab from MeetingTab

**Files:**
- Rewrite: `VoiceBubble/Frontend/Tabs/MeetingTab.swift` (keep filename, rename struct to `RecordTab`)

- [ ] **Step 1: Rewrite MeetingTab.swift as RecordTab**

Same parallel structure as VoiceTab but:
- Default sub-tab: `.settings` (not `.history`)
- Status card includes: start/stop button, timer display, usage instructions
- Settings sub-view wraps `MeetingSettingsSection()`
- History sub-view is a placeholder (no existing meeting history feature yet)

Structure:
```
VStack
├── Status Card (recording state + controls + timer + usage instructions)
├── Segmented Control [设置 | 历史]
└── Content area
    ├── Settings: MeetingSettingsSection in ScrollView
    └── History: placeholder "暂无录音记录" (future feature)
```

Key points from current MeetingTab to preserve:
- Timer management (`elapsedTime`, `timerCancellable`, `updateTimer`, `startTimer`, `formatDuration`)
- Start/stop recording logic (`meetingService.start()`, `meetingService.stop()`)
- Service warning when voice service not ready
- State color logic (`meetingStatusColor`)
- The `warningBanner` helper

Move these into the status card:
- Recording state indicator
- Start/Stop button
- Timer display
- Usage instructions: "同时长按左右 ⌘ 键 0.5 秒，开始/结束录制"

Full rewrite outline:

```swift
import SwiftUI

struct RecordTab: View {
    @EnvironmentObject private var configManager: ConfigManager
    @EnvironmentObject private var voiceService: VoiceService
    @EnvironmentObject private var meetingService: MeetingService

    @State private var selectedSubTab: SubTab = .settings
    @State private var elapsedTime: String = "00:00:00"
    @State private var timerCancellable: Timer?

    private enum SubTab: String, CaseIterable {
        case settings = "设置"
        case history = "历史"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status Card with controls
            statusCard
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, 16)

            // Service warning
            if voiceService.state != .ready {
                warningBanner("请先启动语音服务加载模型")
                    .padding(.horizontal, 32)
                    .padding(.bottom, 16)
            }

            // Segmented Control
            Picker("", selection: $selectedSubTab) {
                ForEach(SubTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 32)
            .padding(.bottom, 16)

            // Content
            Group {
                switch selectedSubTab {
                case .settings:
                    settingsView
                case .history:
                    historyPlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: meetingService.state) { _, newState in
            updateTimer(for: newState)
        }
    }

    // MARK: - Status Card

    private var statusCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // State indicator
                if meetingService.state == .summarizing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Circle()
                        .fill(recordingStatusColor)
                        .frame(width: 10, height: 10)
                }

                Text(meetingService.state.displayText)
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "2C3E6B"))

                Spacer()

                // Start/Stop button
                if meetingService.state == .recording || meetingService.state == .finishing {
                    Button {
                        meetingService.stop()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.circle")
                                .font(.system(size: 14))
                            Text("停止录制")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(Color(hex: "3A4E7A"))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color(hex: "FFB3C1"))
                        .cornerRadius(11)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        meetingService.start()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "record.circle")
                                .font(.system(size: 14))
                            Text("开始录制")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(Color(hex: "3A4E7A"))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color(hex: "A8E6CF"))
                        .cornerRadius(11)
                    }
                    .buttonStyle(.plain)
                    .disabled(voiceService.state != .ready)
                }
            }

            // Timer (visible during recording)
            if meetingService.state == .recording {
                Text(elapsedTime)
                    .font(.system(size: 20, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(hex: "C89828"))
            }

            // Usage instructions
            HStack(spacing: 6) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 12))
                Text("同时长按左右 ⌘ 键 0.5 秒，开始/结束长时录制")
                    .font(.system(size: 12))
            }
            .foregroundColor(Color(hex: "5A7098"))

            // Summary error
            if let error = meetingService.summaryError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "FF6B8A"))
                    Text("摘要生成失败：\(error)")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "FF6B8A"))
                    Spacer()
                }
            }
        }
        .padding(16)
        .glassCard()
    }

    // MARK: - Settings View

    private var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                MeetingSettingsSection()
            }
            .padding(32)
        }
    }

    // MARK: - History Placeholder

    private var historyPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundColor(Color(hex: "C8D8EA"))

            Text("暂无录音记录")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "8AA0BE"))

            Text("长时录制的转写和摘要会记录在这里")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "A8BCD0"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var recordingStatusColor: Color {
        switch meetingService.state {
        case .idle: return Color(hex: "8AA0BE")
        case .recording: return Color(hex: "4ECDC4")
        case .finishing: return .orange
        case .summarizing: return Color(hex: "C89828")
        case .error: return Color(hex: "FF6B8A")
        }
    }

    private func warningBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "FF6B8A"))
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "FF6B8A"))
            Spacer()
        }
        .padding(14)
        .background(Color(hex: "FFF0F3"))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(hex: "FFB3C1"), lineWidth: 1)
        )
    }

    // MARK: - Timer Management

    private func updateTimer(for state: MeetingState) {
        timerCancellable?.invalidate()
        timerCancellable = nil
        switch state {
        case .recording:
            startTimer()
        case .finishing, .summarizing:
            break
        case .idle, .error:
            elapsedTime = "00:00:00"
        }
    }

    private func startTimer() {
        let service = meetingService
        timerCancellable = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            let seconds = service.elapsedSeconds
            elapsedTime = formatDuration(seconds)
        }
    }

    private func formatDuration(_ totalSeconds: Int) -> String {
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
```

- [ ] **Step 2: Build verify**

Run: `cd "/Users/zhangzheng/IDE project/Voice Bubble" && xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

---

### Task 5: Update MeetingSettingsSection Title

**Files:**
- Modify: `VoiceBubble/Frontend/Tabs/Sections/MeetingSettingsSection.swift`

- [ ] **Step 1: Update section titles**

Change references from "会议" to "记录":
- Line 9: `SectionHeader(title: "会议设置")` → `SectionHeader(title: "记录设置")`
- Line 118: `Text("会议摘要 AI 模型")` → `Text("录音摘要 AI 模型")`
- Line 229: `Text("会议摘要提示词")` → `Text("录音摘要提示词")`
- Line 231: Update description text, replace "会议" with "录音"
- Line 94: panel.title = `"选择会议录音保存路径"` → `"选择录音保存路径"`

---

### Task 6: Enhance AboutTab with Usage Instructions

**Files:**
- Modify: `VoiceBubble/Frontend/Tabs/AboutTab.swift`

- [ ] **Step 1: Add usage instructions section**

Insert a new section between `appInfoSection` and `permissionsSection`:

```swift
// MARK: - Usage Instructions
private var usageInstructionsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
        SectionHeader(title: "使用说明")

        VStack(alignment: .leading, spacing: 10) {
            instructionRow(
                icon: "waveform",
                title: "语音输入",
                description: "按住设定的触发键（默认右 ⌘）说话，松开后自动将语音转为文字并输入到当前光标位置"
            )

            instructionRow(
                icon: "record.circle",
                title: "长时录制",
                description: "同时按住键盘左右两侧的 ⌘ 键 0.5 秒即可开始/结束长时录制，结束后自动生成转写和摘要"
            )

            instructionRow(
                icon: "keyboard",
                title: "取消录音",
                description: "录音过程中按 ESC 键可取消本次语音输入，不会输入任何文字"
            )
        }
        .padding(16)
        .glassCard()
    }
}

private func instructionRow(icon: String, title: String, description: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
        Image(systemName: icon)
            .font(.system(size: 13))
            .foregroundColor(Color(hex: "7B8CF5"))
            .frame(width: 20)

        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(hex: "2C3E6B"))

            Text(description)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "5A7098"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
```

Update body to include the new section:
```swift
VStack(alignment: .leading, spacing: 28) {
    appInfoSection
    usageInstructionsSection    // NEW
    permissionsSection
    refreshButton
}
```

---

### Task 7: Final Build and Restart

- [ ] **Step 1: Full build**

Run:
```bash
cd "/Users/zhangzheng/IDE project/Voice Bubble" && xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED

- [ ] **Step 2: Fix any compilation errors**

If build fails, read error output, fix issues, rebuild. Common issues:
- Missing `EnvironmentObject` declarations in new views
- Type mismatches from VoiceSettingsSection removing `@Binding`
- Missing import statements

- [ ] **Step 3: Kill old instance and launch new build**

```bash
pkill -x "VoiceBubble" 2>/dev/null || true
open "/Users/zhangzheng/Library/Developer/Xcode/DerivedData/VoiceBubble-arbvxvbxxsnfymbulsnszkqkgdon/Build/Products/Debug/VoiceBubble.app"
```

- [ ] **Step 4: Verify UI**

Check:
- Sidebar shows: 通用, 语音, 记录, 关于
- 语音 tab shows [设置|历史] segmented control, defaults to 历史
- 记录 tab shows [设置|历史] segmented control, defaults to 设置, has start/stop + timer + usage instructions
- 通用 tab shows only general settings + self-learning section
- 关于 tab shows usage instructions between app info and permissions
