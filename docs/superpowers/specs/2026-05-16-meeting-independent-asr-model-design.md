# 会议独立 ASR 模型选择 — 设计文档

日期：2026-05-16

## 背景与问题

会议录制当前「借用」VoiceService 已加载的 ASR 引擎（`voiceService?.asrEngineRef`）。
这意味着会议的转写模型完全由「通用」Tab 的语音输入设置决定：

- 用户把语音输入设为 **Apple Speech** 时，会议被迫也用 Apple Speech。
- Apple Speech 无法跨语言自动检测，且对会议这种长录音场景，用户更希望用多语言的本地 Qwen 模型。

`MeetingSettingsSection` 里的「语音识别模型」卡片现在是只读镜像，提示"前往通用 Tab 调整"。
代码注释记录：曾经有过独立的会议模型选择器，但它是"幽灵"——配置被持久化却从未在运行时读取，因此被移除。

## 目标

1. 会议录制**固定使用本地 Qwen 模型**，永不使用 Apple Speech。
2. 会议有**独立的模型选择**（0.6B / 1.7B），与语音输入的模型设置完全解耦。
3. 会议模型**只在会议期间存在**：开会时加载（命中缓存即可），结束时卸载，平时不占内存。
4. 语音输入继续使用「通用」Tab 的设置（含 Apple Speech），不受影响。

## 非目标

- 不改语音输入的模型选择逻辑。
- 不为「语音也用 Qwen」做引擎复用优化（见"取舍"——采用方案 A，会议总是加载自己的实例）。
- 不支持会议用云端 ASR。

## 设计

### 1. 配置层

`AppConfig` 新增持久化字段：

- `meetingASRModel: String` — 存 `ASRModel` 的 rawValue，持久化 key `"meetingASRModel"`。
- 默认值 `ASRModel.small.rawValue`（0.6B —— app 自带、通常已缓存）。
- 取值约束：仅 `.small` / `.large`，不含 `.apple`（由 UI 的 Picker 保证，只列出这两项）。

`ConfigManager` 新增访问器：

```swift
var meetingASRModel: ASRModel {
    get { ASRModel(rawValue: appConfig.meetingASRModel).flatMap { $0.isQwen ? $0 : nil } ?? .small }
    set { appConfig.meetingASRModel = newValue.rawValue }
}
```

（若读到非法或 Apple 值，回退 `.small`。）

### 2. MeetingService — 自有引擎生命周期

- **不再**借用 `voiceService?.asrEngineRef`。
- `recordingTask` 中按 `configManager.meetingASRModel.huggingFaceId` 调
  `Qwen3ASRModel.fromPretrained(modelId:progressHandler:)`，包成 `QwenASREngine`。
- 加载完成后再开始录音；命中缓存（speech-swift 的 cache-fast-path 补丁）通常数秒内完成。
- 会议结束（`runRecording` 收尾）与 `cleanup`（异常路径）都调 `asrEngine?.unload()` 再置 nil，
  释放这份模型内存。**这是与现状的关键区别**——现状注释"Don't unload — shared with voice
  service"不再成立。
- `start()` 的模型校验从依赖全局 `configManager.model` 改为依赖 `configManager.meetingASRModel`。

### 3. 新增 `MeetingState.preparing`

按"开始会议"后到录音真正开始之间，存在模型加载/下载窗口（0.6B ~400MB、1.7B ~2.5GB，
未缓存时需下载）。新增状态：

- `MeetingState.preparing`，`displayText` 为"加载会议模型..."。
- `MeetingService` 新增 `@Published var prepareProgress: Double?`，由 `fromPretrained` 的
  progressHandler 写入。
- 录音浮窗（`RecordingOverlayPanel`）在模型就绪、进入 `.recording` 后才弹出。
- `toggle()` 中 `.preparing` 与 `.finishing/.summarizing` 同等对待（忽略点击）。

涉及 `MeetingTab` 的同步改动：

- `isBusy` 计算纳入 `.preparing`。
- `headlineText` 增加 `.preparing` 分支（显示"正在加载会议模型… X%"）。
- `updateTimer` 中 `.preparing` 按 `.idle` 处理（不计时）。

### 4. UI — `MeetingSettingsSection`

把只读的 `asrModelCard` 改为可交互选择卡片：

- 一个 Picker（menu 风格，与「会议语言」卡片一致），选项 `0.6B 极速模式` / `1.7B 精确模式`。
- 固定显示「本地」provenance 徽章。
- 显示选中模型的量化（`MLX 4bit/8bit`）与体积（`~400MB/~2.5GB`）标签。
- 会议进行中（`state != .idle`）禁用 Picker——不允许中途换模型。
- 说明文字改为："会议固定使用本地 Qwen 模型，与语音输入相互独立。首次使用某个模型会自动下载。"

### 5. 保留项（仅更新注释，行为不变）

会议进行时仍通过 `voiceService?.keyboardListenerRef?.isMeetingActive = true` 抑制单键语音输入。
理由由"共享非线程安全引擎"更新为"避免麦克风争用 + 控制双模型内存峰值"。

### 6. 文档同步

更新 `CLAUDE.md`：

- "隐藏的跨服务耦合"表中 `voiceService?.asrEngineRef`（2 处）一项移除——会议不再借用引擎。
- "已知问题 / ASR 共享竞态"相关描述据实更新。

## 取舍记录

**方案 A（采纳）**：会议总是加载自己的 Qwen 实例，结束即卸载。
简单、可预测、严格独立。代价：当语音输入也用同款 Qwen 时，会议期间内存里会有两份模型。

**方案 B（不采纳）**：语音引擎恰为同款 Qwen 时借用它。省内存，但重新引入 CLAUDE.md
标记为 P1 的跨服务耦合。

用户场景为「语音用 Apple」，两方案无差别；选 A 取其干净。

## 验收标准

1. 「通用」Tab 设为 Apple Speech 时，会议仍能正常录制并转写（用 Qwen）。
2. 会议设置里切换 0.6B / 1.7B，下次开会生效。
3. 会议结束后，Qwen 模型被卸载——`/tmp/vb_selflearn_debug.log` 或内存监控显示 RSS 回落。
4. 首次使用未缓存的会议模型时，会议 Tab 显示加载/下载进度，不是无响应。
5. 语音输入的模型选择不受会议设置影响，反之亦然。
