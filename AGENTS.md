# Voice Brother - 项目指南

> macOS 原生语音输入应用。Swift + SwiftUI + MLX，按住说话，松开输入。

## 需求与架构

所有需求定义、数据流、状态机、API 参考均在 `PROJECT.md`。这是唯一的真相来源（single source of truth），开发前必读。

关键章节速查：
| 需要了解 | 查 PROJECT.md 章节 |
|---------|------------------|
| 核心功能与数据流 | 二、核心功能（含完整数据流图） |
| UI 设计参数（色板、间距、动画） | 3.2 视觉风格 |
| 三层架构与目录结构 | 七、架构分层与模块边界 |
| 协议定义（前后端合同） | 7.4 共享层：协议定义 |
| speech-swift API | 九、技术方向 → speech-swift 关键 API |
| 开发阶段划分 | 十、开发阶段 |
| 完整功能清单 | 十一、迁移清单 |

## 平台与约束

这是 **macOS 14+** 应用，不是 iOS。所有技术选型必须面向 macOS：
- **不能用 App Sandbox** — CGEventTap 与沙盒不兼容
- **录音浮窗必须用 NSPanel** — SwiftUI Window 无法实现 `NSFloatingWindowLevel` + 点击穿透 + 不抢焦点
- **Qwen3ASRModel 不是线程安全的** — VoiceService 和 MeetingService 各创建独立模型实例
- **CGEventTap 回调必须快速返回** — 重操作派发到后台线程，回调中只设标志位

## 开发原则

### 前后端解耦
前端只依赖 `Shared/` 层的协议和类型，不依赖后端具体实现。前端可用 Mock 独立开发，后端可用单元测试独立验证。两边通过 `@EnvironmentObject` + `@Published` 通信。

### 视觉风格
保留 Voice Aura 的 **Glassmorphism 风格**，色板和动画参数从 Python 版搬运（见 PROJECT.md 3.2）。布局结构参考 Type4Me 的两栏式设计。注意：Voice Aura 的配色是**自定义色板**，不是系统语义色。

### 从 Python 版翻译
`keyboard_listener.py`、`voice_service.py`、`config.py`、`meeting_service.py` 的核心逻辑可直接翻译。参考 PROJECT.md 第九章"可复用的代码/逻辑"表格。Python 版源码在 `~/IDE project/Voice-Aura/`。

## Skill 路由

| 场景 | 使用的 Skill |
|------|------------|
| SwiftUI 两栏布局、窗口管理、AppKit 互操作、菜单栏、键盘快捷键 | `macos-hig-designer` |
| 毛玻璃材质、卡片/行/徽章组件、间距体系、SF Symbols 用法 | `liquid-glass`（含 `references/components.md` 和 `references/apple-hig.md`） |
| UI 整体设计评审、风格选择、调色板 | `ui-ux-pro-max`（全局 skill） |
| iOS/SwiftUI 通用开发模式（仅参考，注意过滤 iOS-only 内容） | `minimax-skills:ios-application-dev`（全局 plugin） |

### Skill 使用判断
- 写 SwiftUI 视图 → 先查 `liquid-glass` 的组件模式，再对照 `macos-hig-designer` 的 macOS 规范
- 做 NSPanel / AppKit 互操作 → 查 `macos-hig-designer` 第 10 节 AppKit Interop
- 做录音浮窗 → PROJECT.md 4.4 节定义了参数，`macos-hig-designer` 提供 NSPanel 的现代实践

## MCP / 工具路由

| 需要做的事 | 用什么 |
|-----------|-------|
| 查 speech-swift 库的最新 API 或 issue | `zread`（读 GitHub 仓库）或 `gh` CLI |
| 查 Apple 文档 / SwiftUI API | `tavily_search` → `tavily_extract` 读全文 |
| 搜索 macOS 开发最佳实践 | `tavily_search` 或 `web-search-prime` |
| 读任意网页内容 | `tavily_extract`（最完整）→ `web-reader`（快速） |
| 理解开源项目结构/代码 | `zread`（get_repo_structure / read_file / search_doc） |
| 分析截图 / UI 设计稿 / 技术图表 | `zai-mcp-server`（analyze_image / ui_diff_check 等） |
| 读 Voice Aura Python 源码（翻译参考） | 直接 `Read` 工具读 `~/IDE project/Voice-Aura/` |
| 跨会话搜索历史上下文 | `Codex-mem` search（不传 project 参数可全量检索） |

## 开发阶段

```
Phase 1a: 共享层（协议冻结）     ← 必须最先完成
Phase 1b: 后端核心               ← 1a 完成后开始
Phase 2:  设置界面（可与 1b 并行）← 用 Mock 独立开发
Phase 3:  会议纪要               ← 需要 1b 稳定
Phase 4:  增强功能               ← 菜单栏、录音历史等
```

## 修改影响范围（改之前必读）

修改任何文件前，先查此表确认影响范围。**改共享组件必须验证所有消费方仍正常工作。**

### 共享组件 → 消费方

| 共享组件 | 位置 | 被谁使用 | 改了会影响什么 |
|---------|------|---------|--------------|
| **RecordingOverlayPanel** (singleton) | `Frontend/Components/RecordingOverlayPanel.swift` | VoiceService（4处）、MeetingService（3处） | 改外观/动画 → 语音和会议的浮窗都变；改 API 签名 → 两个 Service 都要同步改 |
| **RecordingWaveformView** | `Frontend/Components/RecordingWaveformView.swift` | RecordingOverlayPanel（嵌入） | 改波形 → 语音和会议录音时的浮窗动画都变 |
| **ColorExtension + glassCard** | `Frontend/Components/ColorExtension.swift` | 所有 Tab 页（GeneralTab、VocabularyTab、HistoryTab、MeetingTab、AboutTab） | 改颜色/修饰符 → 全部页面视觉受影响 |
| **GlassmorphismBackground** | `Frontend/Components/GlassmorphismBackground.swift` | MainWindow（背景） | 改动画/气泡 → 整个应用背景变化 |
| **TextProcessor** | `Backend/Voice/TextProcessor.swift` | VoiceService、MeetingService | 改语气词过滤 → 两个服务的转写结果都变；注意：会议只用 `removeFillers`，不用替换规则 |
| **ConfigManager** | `Backend/Services/ConfigManager.swift` | 所有 Tab 页 + VoiceService + MeetingService | 改配置项/持久化逻辑 → 全局影响 |
| **Protocols.swift** | `Shared/Protocols.swift` | 所有 Service + 所有用 @EnvironmentObject 的 View | 改协议 = 改合同，前后端都要同步 |
| **Types.swift** | `Shared/Types.swift` | 全局 | 改枚举/结构体 → 所有引用方都要适配 |

### 隐藏的跨服务耦合（改 VoiceService 内部也可能炸 MeetingService）

MeetingService 直接访问了 VoiceService 的内部属性，**不在 Protocol 里**，所以改 VoiceService 内部结构时容易遗漏：

| MeetingService 代码 | 访问的 VoiceService 内部 | 风险 |
|--------------------|-----------------------|------|
| `voiceService?.keyboardListenerRef?.isMeetingActive = true` (多处) | `keyboardListenerRef` 属性 + `isMeetingActive` 标志（**已改为锁保护 getter/setter**） | 重命名/重构 KeyboardListener 时会炸 |

**修改 VoiceService 时必须同时检查 MeetingService 对 `keyboardListenerRef` 的引用。**
ASR engine 不再共享——会议按 `meetingASRModel` 配置加载自己的 Qwen 实例，结束即 `unload()`。

### 安全修改区域（改了不影响其他模块）

| 文件 | 可以安全修改的范围 |
|------|-----------------|
| `Backend/Voice/VoiceService.swift` | 内部实现逻辑（不改 Protocol 接口的前提下）；**但要注意上面的隐藏耦合** |
| `Backend/Meeting/MeetingService.swift` | 内部实现逻辑（不改 Protocol 接口的前提下） |
| `Frontend/Tabs/GeneralTab.swift` | 页面布局和交互（只影响通用设置页） |
| `Frontend/Tabs/VocabularyTab.swift` | 页面布局和交互（只影响词汇页） |
| `Frontend/Tabs/HistoryTab.swift` | 页面布局和交互（只影响历史页） |
| `Frontend/Tabs/MeetingTab.swift` | 页面布局和交互（只影响会议页） |
| `Frontend/Tabs/AboutTab.swift` | 页面布局和交互（只影响关于页） |
| `Backend/Services/HistoryManager.swift` | 内部 SQLite 逻辑（不改 actor 接口的前提下） |
| `Backend/Services/PermissionManager.swift` | 内部实现（不改 Protocol 接口的前提下） |

### 修改守则

1. **改共享组件前**：先 grep 所有消费方，确认修改不会破坏它们
2. **改 VoiceService 内部结构前**：检查 MeetingService 对 `keyboardListenerRef` 的直接访问（ASR engine 已不再共享）
3. **改 RecordingOverlayPanel 的 show/hide 逻辑前**：注意动画 completionHandler 的异步竞态（见已知问题）
4. **改 Protocol 接口**：前后端必须同步更新，编译验证
5. **改 Types/枚举**：全局搜索所有 switch/case，确认无遗漏
6. **改完后必须自动构建并重启应用**（用户不使用 Xcode，所有操作由命令行完成）：
   ```bash
   # 1. 构建
   cd "~/IDE project/Voice Brother"
   xcodebuild build -project VoiceBrother.xcodeproj -scheme VoiceBrother -quiet

   # 2. 关闭正在运行的旧实例
   pkill -x "VoiceBrother" 2>/dev/null || true

   # 3. 启动新构建的应用
   open "~/Library/Developer/Xcode/DerivedData/VoiceBrother-dopowvwzswipvocptpcwzjpqinvh/Build/Products/Debug/VoiceBrother.app"
   ```
   **每次修改代码后都必须执行这三步**，不要只构建不重启，也不要让用户手动去操作。

## 外部依赖补丁（SPM checkout patch）

### speech-swift `HuggingFaceDownloader.downloadWeights` 加 cache-fast-path

**位置**：`~/Library/Developer/Xcode/DerivedData/VoiceBrother-*/SourcePackages/checkouts/speech-swift/Sources/AudioCommon/HuggingFaceDownloader.swift`

**为什么打这个补丁**：原版每次启动都调 `hub.snapshot()`，命中缓存的情况下仍然向 HuggingFace 发 6+ 次 HEAD 请求验证 etag。国内网络下额外多花 5-30 秒，体感"模型启动太久"。

**补丁内容**：
1. 在 `downloadWeights` 函数开头增加 `if isLocalCacheComplete(...) { progressHandler?(1.0); return }`
2. 新增静态方法 `isLocalCacheComplete(directory:additionalFiles:)`，检查 config.json + 至少一个 .safetensors + 所有非 glob 的 additionalFiles + `.cache/huggingface/download/*.metadata` 都存在

**判断完整性的依据**：HF metadata 文件只有在下载完整成功且写入 commit_hash/etag 后才会生成，所以它存在 ⇔ 文件不是半成品。

**何时需要重打**：
- 删除 `~/Library/Developer/Xcode/DerivedData/VoiceBrother-*` 之后
- `Package.resolved` 里的 speech-swift 版本变更后（SPM 会重新 fetch）
- 任何触发 SPM resolve 的操作之后

**重打步骤**：在补丁文件内搜 `VoiceBrother local patch` 找原位置，参照 git diff 重新粘贴两段。

**根治方向**：往 speech-swift 上游提 PR 加 `localFilesOnly: Bool` 参数，命中缓存时跳过 hub.snapshot。

## 已知问题（待修复）

### ✅ 已修：P0 RecordingOverlayPanel 动画竞态
已通过 `showToken` 引用计数解决。hide 的 completionHandler 在 token 变化时 bail out，不会再把新 show 的状态擦掉。

### ✅ 已修：ASR 共享竞态（已彻底消除）
会议不再借用 VoiceService 的 engine——`MeetingService` 按 `configManager.meetingASRModel`
加载自己的 Qwen 实例（`.preparing` 状态下加载，结束时 `unload()`）。两个服务的 ASR engine
完全独立，不存在共享竞态。MeetingService.cleanup 仍 await 自己的 `pendingTranscriptionTask`。

### ✅ 已修：P0 MLX cache 失控（22+ GB RSS）
**症状**：长时间使用后进程 RSS 涨到 20+ GB，最终触发 swap 颠簸。
**根因**：MLX 默认 `cacheLimit = memoryLimit`（32GB Mac 上几乎等于无限制）。每次 `transcribe` 的音频长度不同 → 中间张量/KV-cache buffer 形状不同 → MLX 的 buffer 池**无法复用**变形 buffer，全部缓存沉积。文档原话："by the end of a long inference run, you may see several GB of cached memory ... if cache memory is unconstrained"。
**修复**：新增 `Backend/Voice/MLXMemoryGovernor.swift`，启动时 `MLX.Memory.cacheLimit = 256 MB`，每次转写后调 `Memory.clearCache()`。接入点：
- `VoiceBrotherApp.init()` 调 `configure()`
- `VoiceService.transcribeAndInject` / `runPreviewTranscription`、`MeetingService.transcribeSegment`、`MeetingRetranscriber` 在转写完成后调 `reclaim()`
- 调 `snapshotDescription()` 写日志便于回归监控

**验证方法**：观察 `/tmp/vb_selflearn_debug.log` 中 `MLX active=... cache=...`，正常时 cache 应在每次转写后回到 0。
**回归红线**：如果 active 持续上涨（不只是 peak），说明有新的 MLX 数组被作为长期持有的属性挂住了。

### P1（未修）：MeetingService 穿透访问 VoiceService 内部
`voiceService?.keyboardListenerRef?.isMeetingActive` 绕过 Protocol 层。**已用锁保护 `isMeetingActive` getter/setter**，但架构层面仍破坏了前后端解耦。后续可在 VoiceServiceProtocol 中添加 `func setMeetingActive(_:)`。（`asrEngineRef` 穿透已随会议独立模型一并移除。）

### P2（未修）：GeneralTab / VoiceSettingsSection 过大
目标：每个 Tab 文件控制在 250 行以内。

## 注意事项

- 会议纪要的转写**只执行语气词过滤**，不执行替换规则，不传热词
- 替换规则必须存储为**有序数组**，不能用 Swift Dictionary
- 剪贴板恢复前必须检查 `changeCount` 防止竞态
- 双 Command 触发会议时，正在进行的语音录音**立即取消**
