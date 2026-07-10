# Voice Brother - 项目指南

> macOS 原生语音输入应用。Swift + SwiftUI + MLX，按住说话，松开输入。

## 需求与架构

早期内部规格 `PROJECT.md` 已在开源时移除（commit `d7bb1a0`），不再存在。现在的真相来源 = **代码本身** + 本文件下方各表（平台约束 / 开发原则 / 修改影响范围）+ `README.md` 的功能清单。

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
保留 Voice Aura 的 **Glassmorphism 风格**，色板和动画参数从 Python 版搬运。布局结构参考 Type4Me 的两栏式设计。注意：Voice Aura 的配色是**自定义色板**，不是系统语义色。

### 从 Python 版翻译（已完成，历史信息）
核心逻辑当初从 Voice Aura Python 版翻译而来。**Python 源码目录 `~/IDE project/Voice-Aura/` 已删除**，翻译已全部落地到 Swift 代码，无需再回看。

## Skill 路由

早期路由的 `macos-hig-designer` / `liquid-glass` / `ui-ux-pro-max` / `minimax-skills:ios-application-dev` **已全部卸载，不复存在**（2026-06-10 harness 体检确认），不要再尝试调用。现行做法：
- 写 SwiftUI 视图 / 毛玻璃风格 → 直接参考 `Frontend/Components/` 现有组件（ColorExtension、GlassmorphismBackground 等），风格已沉淀在代码里
- 做录音浮窗 → 参数见 `RecordingOverlayPanel.swift`
- UI 设计评审需要时 → `ui-ux-pro-max` 等可重新安装后再路由，安装前别引用

## MCP / 工具路由

| 需要做的事 | 用什么 |
|-----------|-------|
| 查 speech-swift 库的最新 API 或 issue | `zread`（读 GitHub 仓库）或 `gh` CLI |
| 查 Apple 文档 / SwiftUI API | `tavily_search` → `tavily_extract` 读全文 |
| 搜索 macOS 开发最佳实践 | `tavily_search` 或 `web-search-prime` |
| 读任意网页内容 | `tavily_extract`（最完整）→ `web-reader`（快速） |
| 理解开源项目结构/代码 | `zread`（get_repo_structure / read_file / search_doc） |
| 分析截图 / UI 设计稿 / 技术图表 | `zai-mcp-server`（analyze_image / ui_diff_check 等） |
| 跨会话搜索历史上下文 | `sess` skill（cc-memory；`claude-mem` MCP 已不存在） |

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
| **RecordingOverlayPanel** (singleton) | `Frontend/Components/RecordingOverlayPanel.swift` | 后端经 `Shared/OverlayPresenting.swift` 协议注入（两 facade + 协作者共 23 处调用；仅两 facade init 默认值引用 `.shared`） | 改外观/动画 → 语音和会议的浮窗都变；改 API 签名 → 同步改 OverlayPresenting 协议 + 便捷重载的默认值 |
| **RecordingWaveformView** | `Frontend/Components/RecordingWaveformView.swift` | RecordingOverlayPanel（嵌入） | 改波形 → 语音和会议录音时的浮窗动画都变 |
| **ColorExtension + glassCard** | `Frontend/Components/ColorExtension.swift` | 所有 Tab 页（GeneralTab、VocabularyTab、HistoryTab、MeetingTab、AboutTab） | 改颜色/修饰符 → 全部页面视觉受影响 |
| **GlassmorphismBackground** | `Frontend/Components/GlassmorphismBackground.swift` | MainWindow（背景） | 改动画/气泡 → 整个应用背景变化 |
| **TextProcessor** | `Backend/Voice/TextProcessor.swift` | VoiceService、MeetingService | 改语气词过滤 → 两个服务的转写结果都变；注意：会议只用 `removeFillers`，不用替换规则 |
| **ConfigManager** | `Backend/Services/ConfigManager.swift` | 所有 Tab 页 + VoiceService + MeetingService | 改配置项/持久化逻辑 → 全局影响 |
| **Protocols.swift** | `Shared/Protocols.swift` | 所有 Service + 所有用 @EnvironmentObject 的 View | 改协议 = 改合同，前后端都要同步 |
| **Types.swift** | `Shared/Types.swift` | 全局 | 改枚举/结构体 → 所有引用方都要适配 |

### 跨服务耦合（已收敛到 Protocol，2026-07-03 重构）

原 `voiceService?.keyboardListenerRef?.isMeetingActive` 穿透已消除：MeetingService 一律走 `voiceService?.setMeetingActive(_:)`（VoiceServiceProtocol 方法，内部仍是锁保护）。`keyboardListenerRef` getter 仅 VoiceService 自用。
ASR engine 不再共享——会议按 `meetingASRModel` 配置加载自己的 Qwen 实例，结束即 `unload()`。

### 服务内部结构（2026-07-03 重构后：facade + 协作者）

两个 Service 均为 facade（conform Protocol、持全部 @Published、持协作者强引用），协作者经 weak 回引读 facade：
- **VoiceService（~1020行）** + `Backend/Voice/`：VoiceAudioChunkStore（线程安全音频缓冲）、AudioEngineController（引擎生命周期+tap+输入设备）、TranscriptionPipeline（转写→注入→润色，**含 MLX reclaim**）、FeedbackSoundPlayer（反馈音）
- **MeetingService（~490行）** + `Backend/Meeting/`：MeetingAudioPrimitives（线程安全原语）、MeetingTranscriptWriter（markdown+软合并）、MeetingRecordingLoop（录音循环+混音+VAD 切段）、MeetingSegmentTranscriber（段转写，**含 MLX reclaim**）
- 红线：@Published 只许在 facade；startGeneration / pendingTranscriptionTask 守卫留 facade；SCStreamOutput conformance 留在 MeetingService extension（转发给 loop）

### 安全修改区域（改了不影响其他模块）

| 文件 | 可以安全修改的范围 |
|------|-----------------|
| `Backend/Voice/VoiceService.swift` 及其 4 协作者 | 内部实现逻辑（不改 Protocol 接口、守住上面"服务内部结构"红线的前提下） |
| `Backend/Meeting/MeetingService.swift` 及其 4 协作者 | 内部实现逻辑（同上） |
| `Frontend/Tabs/GeneralTab.swift` | 页面布局和交互（只影响通用设置页） |
| `Frontend/Tabs/VocabularyTab.swift` | 页面布局和交互（只影响词汇页） |
| `Frontend/Tabs/HistoryTab.swift` | 页面布局和交互（只影响历史页） |
| `Frontend/Tabs/MeetingTab.swift` | 页面布局和交互（只影响会议页） |
| `Frontend/Tabs/AboutTab.swift` | 页面布局和交互（只影响关于页） |
| `Backend/Services/HistoryManager.swift` | 内部 SQLite 逻辑（不改 actor 接口的前提下） |
| `Backend/Services/PermissionManager.swift` | 内部实现（不改 Protocol 接口的前提下） |

### 修改守则

1. **改共享组件前**：先 grep 所有消费方，确认修改不会破坏它们
2. **改 VoiceService 内部结构前**：跨服务只剩 `setMeetingActive(_:)` 协议方法一条通道（keyboardListenerRef 穿透已消除，ASR engine 已不再共享）
3. **改 RecordingOverlayPanel 的 show/hide 逻辑前**：注意动画 completionHandler 的异步竞态（见已知问题）
4. **改 Protocol 接口**：前后端必须同步更新，编译验证
5. **改 Types/枚举**：全局搜索所有 switch/case，确认无遗漏
6. **改完后必须自动构建并重启应用**（用户不使用 Xcode，所有操作由命令行完成）。**只走 Release 构建 + `/Applications/Voice Brother.app` 固定路径**，否则 TCC 权限每次重建都会被 macOS 重置（详见下面"为什么必须 Release"）：
   ```bash
   # 0. 先 resolve 依赖并给 speech-swift 打 cache-fast-path 补丁（幂等，必须在 build 前）
   xcodebuild -resolvePackageDependencies \
     -project "~/IDE project/Voice Brother/VoiceBrother.xcodeproj" \
     -scheme VoiceBrother \
     -derivedDataPath "~/IDE project/Voice Brother/build/.tmp-build" \
     -skipPackagePluginValidation
   bash "~/IDE project/Voice Brother/scripts/patch-speech-swift.sh"

   # 1. Release 构建到临时路径（关掉 base entitlements 注入，避免 get-task-allow）
   xcodebuild build \
     -project "~/IDE project/Voice Brother/VoiceBrother.xcodeproj" \
     -scheme VoiceBrother \
     -configuration Release \
     -derivedDataPath "~/IDE project/Voice Brother/build/.tmp-build" \
     -skipPackagePluginValidation \
     CODE_SIGN_IDENTITY="VoiceBubble Dev" \
     CODE_SIGN_STYLE=Manual \
     DEVELOPMENT_TEAM="" \
     CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO

   # 2. 关闭旧实例 + ditto 覆盖到 /Applications + 清理临时目录
   # 用 osascript 干净退出（触发 applicationWillTerminate → 写 [Lifecycle] clean exit
   # 并清除 dirty-flag）。pkill 发 SIGTERM 不触发该回调，会在日志里留一条假的
   # "previous session ended ABNORMALLY"。osascript 失败（app 卡死）才 fallback 到 pkill。
   osascript -e 'quit app "Voice Brother"' 2>/dev/null || true
   sleep 1
   pkill -x "VoiceBrother" 2>/dev/null || true
   rm -r "/Applications/Voice Brother.app" 2>/dev/null
   ditto "~/IDE project/Voice Brother/build/.tmp-build/Build/Products/Release/VoiceBrother.app" "/Applications/Voice Brother.app"
   rm -r "~/IDE project/Voice Brother/build/.tmp-build"

   # 3. 启动新版
   open "/Applications/Voice Brother.app"
   ```
   **每次修改代码后都必须执行这三步**，不要只构建不重启，也不要让用户手动去操作。
   构建末尾偶尔会报 `accessing build database ... disk I/O error`（LaunchServices 注册步骤的小故障），**不影响产物**，已签名好的 .app 会照常生成，忽略即可。

   **为什么必须 Release 而不是 Debug**：Debug 构建的 entitlements 自动注入 `get-task-allow=true`（允许 lldb 附加），macOS TCC 把带这个 flag 的 binary 视为"可被任意篡改"，**不持久缓存敏感权限**（辅助功能 / 输入监控），每次重建都会要求重新授权 → 弹密码。Release 构建 + `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` 干净 entitlements + 固定 `/Applications` 路径 = TCC 按 designated requirement 长期缓存权限，重建多少次都不弹。

## 外部依赖补丁（SPM checkout patch）

### speech-swift `HuggingFaceDownloader.downloadWeights` 加 cache-fast-path

**打法（2026-06-10 起自动化）**：`scripts/patch-speech-swift.sh` 在构建第 0 步自动打（见上方构建命令），锚点字符串替换、幂等。**不再需要手工重打**——构建流程本身每次 resolve 后都会重新打。

> 历史教训：补丁曾只手工打在 DerivedData 里，而实际构建用的 checkout 在 `build/.tmp-build/SourcePackages`（且每次构建后被 rm），导致补丁静默蒸发、文档却声称生效（2026-06-10 harness 体检发现线上版本一直没补丁）。**补丁必须长在构建流程里，不能长在某个会被删的目录里。**

**为什么打这个补丁**：原版每次启动都调 `hub.snapshot()`，命中缓存的情况下仍然向 HuggingFace 发 6+ 次 HEAD 请求验证 etag。国内网络下额外多花 5-30 秒，体感"模型启动太久"。

**补丁内容**：
1. 在 `downloadWeights` 函数开头增加 `if isLocalCacheComplete(...) { progressHandler?(1.0); return }`
2. 新增静态方法 `isLocalCacheComplete(directory:additionalFiles:)`，检查 config.json + 至少一个 .safetensors + 所有非 glob 的 additionalFiles + `.cache/huggingface/download/*.metadata` 都存在

**判断完整性的依据**：HF metadata 文件只有在下载完整成功且写入 commit_hash/etag 后才会生成，所以它存在 ⇔ 文件不是半成品。

**锚点失配时**：speech-swift 上游改了 `HuggingFaceDownloader.swift` 会让脚本报错退出（不会静默跳过），此时参照脚本内的两段 Swift 代码人工重新移植。

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

### ✅ 已修：显示主窗口点击无效
主窗口由 `WindowGroup` 改为单实例 `Window(id:"main")`——WindowGroup 窗口关闭即销毁、从 NSApp.windows 移除，菜单"显示主窗口"的遍历兜底因此空跑。改用 `MainWindowOpener` 单例桥接 SwiftUI `openWindow`，菜单 / ⌘, / Dock 重开三条路径统一走它。**不要改回 WindowGroup。**（`WindowCornerRadius.swift` 已有同名 `WindowAccessor`，桥故命名 MainWindowOpener 避让。）

### ✅ 已修：自学习引擎误学常用词 + 坏规则夜间复活
学习规则有**两条独立来源**，排查误学必须都查：
1. App 内 `CorrectionLearningEngine`（HistoryTab 编辑触发，有 `nonLearnableTerms` 黑名单 + `applyReplacements` 对纯 ASCII `from` 按词边界匹配，防 `20` 误伤 `2026`）
2. `extensions/dynamic-hotwords/update_hotwords.py` —— **launchd 每晚 22:00** 从 history.db 挖规则，`defaults write` 直接写进 UserDefaults 手动区并**重启 app**；app 启动时 `migrateOrphanedLearnedRules` 把它们搬进 learned_rules.json

「好了→我的ext」反复复活的根因 = 路径 2 绕过 learn() 的黑名单闸。已修（2026-06-10）：脚本端 `is_replacement_candidate` 加 `CJK_NON_LEARNABLE` 黑名单 + 修 `isalnum()` 误把汉字当字母数字（限定 ASCII，恢复"拒中文→中文规则"原意）；app 端 `evictNonLearnableRules()` 启动清扫兜底。
**回归红线**：① 黑名单闸必须在 `learn()` 的 REVERT 分支**之后**，否则 `to` 是常用词的已学规则永远撤不掉；② Swift 与 Python 两份黑名单需手动同步；③ learning.log 里若再现 22:00 MIGRATE 行带常用词规则 = 复活回路回归。坏规则数据 + 清理见 memory。

### ✅ 已修：闲置时被系统强杀（"app 自己关了、要手动重开"）
**症状**：电脑闲置时进程消失，**无 .ips 崩溃报告**、内存健康、彻底退出（不自重启），下次启动 `[Lifecycle]` 记 `ABNORMALLY`。
**根因**：AppKit 默认给 Cocoa app 开 **Sudden Termination**，且代码从未持有任何 activity 断言 → 系统空闲回收时把它当"可回收后台进程"直接 SIGKILL，跳过 `applicationWillTerminate`（所以 clean-exit 面包屑没写 → 判异常）。对常驻菜单栏、要随时响应全局按键的工具是致命的。
**修复（2026-06-22）**：`AppDelegate.applicationDidFinishLaunching` 里 `ProcessInfo.disableSuddenTermination()` + `beginActivity([.background, .suddenTerminationDisabled, .automaticTerminationDisabled])`，token 存 `residentActivityToken` 强引用挂整个进程生命周期。
**回归红线**：① `residentActivityToken` 必须是 AppDelegate 的长期属性，删了 / 改成局部变量 → 断言立即释放，空闲强杀复活；② 验证看 `grep -c ABNORMALLY /tmp/vb_selflearn_debug.log` 闲置一两天不再涨。
**注**：确切 kill 信号需 `log show` 读统一日志确认，本次修复基于配置层强推断（签名有效、内存健康、非 OOM、非 relaunchApp 自重启均已排除）。

### ✅ 已修（2026-07-03 重构）：P1 穿透 + P2 胖文件 + 上帝对象 + 浮窗依赖反转
- P1：VoiceServiceProtocol 加 `setMeetingActive(_:)`，MeetingService 5 处穿透全部改走协议
- P2：VoiceSettingsSection 1109→7 文件、HistoryTab 848→7 文件，全部 ≤250 行
- 上帝对象：VoiceService 2234→facade 1021 + 4 协作者；MeetingService 1368→facade 489 + 4 协作者（见"服务内部结构"）
- 依赖反转：后端 23 处 `RecordingOverlayPanel.shared` 直调改走 `Shared/OverlayPresenting.swift` 协议注入
全程纯结构重组、零行为变更；三轮独立验收（构建绿 + 高危块逐行 diff 等价 + 红线 grep 全过）。

### ✅ 已修（2026-07-09）：学习管道空转 —— 配对层是坏的 + 学不到东西

**实证的两个病**：
1. 6–7 月 11739 次转写，用户手动纠错 **0 次**，`learned_rules.json = []`。用户对大模型说话，错字被 LLM 意会 → 没动机去历史页手动改 → 学习引擎输入为空。
2. `update_hotwords.py` 的旧配对（时间窗 ±90s + Levenshtein 挑最近）**全是乱配**：590 对里 `dist==0` 有 **0** 对；一条 user msg 被 5 条 ASR 记录抢配。北极星 `mean_edit_rate≈0.54` 测的是乱配率，不是编辑率。已 `os.rename` 归档为 `edit_distance_daily.json.v1-invalid`，**不要当历史数据读**。

**三段修复**（引擎无关，全部在 ASR 输出之后）：

| 层 | 文件 | 作用 |
|---|---|---|
| 运行时吸附 | `Backend/Voice/HotwordSnapper.swift` | `G L M`→`GLM`、`simu link`→`simulink`。normalize **完全相等**才吸附 → 零误伤 |
| 学习闸门 | `Backend/Voice/PhoneticGate.swift` | 发音不相近就不学。独立拦住 `好了→我的ext` 类事故，不再只靠停用词表 |
| 信号源 | `extensions/cc-prompt-log/` hook + `update_hotwords.py` 的 `mine_anchored_pairs()` | hook 记下每次提交的 prompt 原文 → 锚定对齐 ASR 注入文本 → diff 出真错字；锚定失败的送 GLM 复核 |

**两份词表，不是一份**（`CorrectionLearningEngine`）：
- `officialSpellings()` = 热词 ∪ 手动规则 `to` ∪ **已学规则 `to`** —— 吸附器的目标词，谁引入的都算
- `admissionWhitelist()` = 热词 ∪ 手动规则 `to` —— PhoneticGate ch3 的白名单，**只认外部来源**

**回归红线**：
0. `admissionWhitelist()` 绝不能含已学规则的 `to`。否则 ch3 退化成「这条规则的目标词在词表里，因为这条规则在」，每条 ASCII 目标的坏规则都**自我批准**。实测 `好了 → 我的ext` 走到 ch3：`contains("我的ext")` 真（它是自己的 `to`）+ `isMostlyASCIIAlnum` 真（3/5）→ 放行，`evictNonLearnableRules()` 清扫失效。也**不能**改写成 `officialSpellings().subtracting([rule.to])`：`cloud → Claude` 的 `Claude` 同时由热词表提供，按字符串抹掉会误杀这条合法规则。排除的是「已学规则这一来源」，不是某个字符串。Python 侧 `known_targets()` 是同一份语义的镜像。
1. `PhoneticNormalize.key()` 是 **唯一** normalize 实现，snapper 和 gate 共用。别在任一侧再写一份。
2. `PhoneticGate.swift` 是**权威**；`update_hotwords.py` 的 `phonetic_gate()` 是**故意放宽**的镜像（pypinyin 逐字 `heteronym=True` 读音集合求交）。因为 pypinyin 读「朴」为 `piao`、Swift `CFStringTransform` 读为 `pu` → 同一对 `质朴→智谱` 两侧判决相反。**宽→严是安全方向**：Python 多捞，Swift 终审，`evictNonLearnableRules()` 每次启动清扫。反过来会静默漏学。
3. `PhoneticGate` 的 ch2（纯 CJK）必须**就地 return**，不许下落到 ch3。
4. 吸附器必须跑在 `applyReplacements` **之后**（`TextProcessor.process()` 返回后）。否则 `code x` 先被吸附成热词 `Codex`，用户显式规则 `code x → CodeX` 永远匹配不到。这条顺序收在 `TranscriptionPipeline.processTranscript()` 一个函数里——云端 / 本地两条 ASR 路径都调它，**不要再在别处重写这段后处理**。
5. **连续单字符 token 是原子段**，不许从中间截。生产语料实测：不加这条会把 `A P I key` 吸成 `A PI key`、`K I C A D` 吸成 `K IC A D`（短热词 `PI`/`IC`/`DC` 从长串中间命中）。
6. **只差大小写的不吸附**。热词表里有 `Wait`/`Actually`/`skill`/`token` 这类普通英文词，否则 `please wait`→`please Wait`。
7. `cc_prompt_log.py` 必须**完全静默**（UserPromptSubmit 的 stdout 会被注入模型上下文）且时间戳必须是 **UTC + `Z`**（`time.gmtime()`）。history.db / DebugLog / learning.log 全是 UTC+Z（实测 11067/11067 行）。写本地时间 → 锚定整体错开 9 小时、一条配不上、**不报任何错**。
8. GLM 复核喂的是 `raw_text`（ASR 原文）不是注入文本，否则挑出的是 polish 产物，随后被 `raw_text` 回查全部打掉，白花钱。缓存 `state/glm_cache.json` 按 `sha1(raw_text)` 键，删了会对同一批失败样本重复计费。
9. 机械候选与 GLM 候选**同一条闸门链、零豁免**（`passes_gate_chain`），频次闸 ≥2 在合并后的 `rule_counts` 上统一施加 → GLM 单次命中无法自我晋升。
10. **所有时间窗口一律 `datetime.utcnow()`**。history.db 的 `created_at`、Claude jsonl 的 `timestamp`、hook 的 `ts` 全是带 Z 的 UTC。拿 `datetime.now()` 去比会把窗口前端砍掉 9 小时（JST），静默丢数据。DB 行只从 `_load_history_rows()` 一处进来。
11. 锚定循环只有一份：`anchor_segments()`。`calibrate_anchor.py` 必须消费它而不是复制它——校准脚本是给生产算法打分的，各写一份就会给另一个算法打分。

**新产物**：`~/Library/Application Support/VoiceBrother/learning/` 下 `prompt_submissions.jsonl`（hook 写，0600，保留 35 天）、`snapper_hits.json`（吸附命中记账）。
**校准**：`extensions/dynamic-hotwords/calibrate_anchor.py`（只读）。判死判活看 `dist0 占比`——旧管道 0%，新管道 96.1%。

## 注意事项

- 会议纪要的转写**只执行语气词过滤**，不执行替换规则，不传热词
- 替换规则必须存储为**有序数组**，不能用 Swift Dictionary
- 剪贴板恢复前必须检查 `changeCount` 防止竞态
- 双 Command 触发会议时，正在进行的语音录音**立即取消**
