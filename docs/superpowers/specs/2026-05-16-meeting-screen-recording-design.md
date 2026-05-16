# 会议录屏功能 — 设计文档

> 日期：2026-05-16
> 状态：已定稿，待实现

## 1. 目标

给会议/对话录制功能增加**屏幕录制**能力。开启后，会议全程录下主显示器的画面，连同声音（麦克风 + 系统音）写成一个 `.mov` 视频文件，与现有的对话记录 markdown、对话录音 WAV 一同保存。

## 2. 权限结论

**无需任何新权限。** macOS 的「屏幕录制」是单一 TCC 权限，授权后同时覆盖「录屏幕画面」和「采集系统音频」。会议功能现已依赖它采集系统音频：

- `Info.plist` 已有 `NSScreenCaptureUsageDescription`
- `PermissionManager` 已处理屏幕录制权限的预检、申请、授权后重启横幅
- `MeetingService` 已运行一个 `SCStream`，目前只配了 `capturesAudio = true`，未取视频帧

录屏 = 在同一个 `SCStream` 上多配一路视频输出。不改 entitlements、不加 Info.plist key。

## 3. 用户决策（已确认）

| 项 | 决定 |
|----|------|
| 产物形式 | 完整录屏视频文件 `.mov` |
| 捕获范围 | 整个主显示器全屏 |
| 视频音轨 | 带声（麦克风 + 系统音混音） |
| 画质帧率 | 1080p、10fps（低帧率省空间） |
| 启动方式 | 配置项持久化，默认关；开关控件放在 MeetingTab UI 内 |
| WAV 文件 | 录屏开启时仍照常写并**保留**（不删除），录屏纯属额外产物 |

## 4. 实现方案（思路 A：复用现成混音流）

`MeetingService` 的录制循环每 0.5s 已把麦克风 + 系统音 `mixAudio` 成一路 16kHz 单声道 `mixed`，用于喂 ASR 和写 WAV。录屏视频的音频直接复用这路 `mixed`，不另开音频采集，不做额外混音。

被否决的备选：
- **B（为视频单独采高保真音频）** — 复杂度高，且会议存档本就 16kHz，单开一套不一致也不值。
- **C（先录哑视频，结束后混入 WAV）** — 长会议结束时要做一次大文件后处理，期间视频无声，磁盘 I/O 翻倍。

## 5. 组件设计

### 5.1 配置项 — `ConfigManager`

新增 `meetingScreenRecording: Bool`，持久化（UserDefaults），默认 **`false`**。

会议**开始时读一次快照**，会议进行中修改不影响当前这场。

### 5.2 新文件 — `Backend/Meeting/MeetingScreenRecorder.swift`

封装 `AVAssetWriter`，独立于 `MeetingService`，对外接口：

| 成员 | 职责 |
|------|------|
| `start(outputURL:displaySize:)` | 建 `AVAssetWriter`：视频输入 H.264（`expectsMediaDataInRealTime = true`），音频输入 AAC 16kHz 单声道 |
| `SCStreamOutput` 实现 | 接收 `.screen` 类型 `CMSampleBuffer`，仅写 `SCFrameStatus == .complete` 的帧；首帧 `.complete` 的 PTS 作为 writer session t0 |
| `appendAudio(_ samples: [Float])` | 接收 `MeetingService` 混好的 `mixed` 采样，转 `CMSampleBuffer` 后写音频输入；PTS 按累计采样数推算 |
| `finish() async` | 正常收尾，`finishWriting`；返回是否成功 |
| `cancel()` | 取消 writer 并删半成品文件 |

内部一条**串行队列**序列化所有 writer 操作（视频帧来自 SCStream 回调线程，音频来自 `MeetingService` 录制 Task，需序列化）。

**失败自废原则**：writer 启动失败或中途 append 失败 → 置内部 `failed` 标志、停止接收、记日志，**不向 `MeetingService` 抛错**。录屏永远不能拖垮会议。

### 5.3 `MeetingService` 改动

在录制 Task 里，`SCStream` 创建成功后，若 `meetingScreenRecording` 快照为开：

1. 给 `SCStreamConfiguration` 补视频参数：
   - 按主显示器宽高比，把高缩到 ≤ 1080，宽等比换算，宽高都取偶数
   - `minimumFrameInterval = CMTime(value: 1, timescale: 10)`（10fps）
   - `pixelFormat = kCVPixelFormatType_32BGRA`
2. 建 `MeetingScreenRecorder`，调 `start(...)`
3. `stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue:)`
4. 混音循环算出 `mixed` 后，多调一行 `recorder.appendAudio(mixed)`

文件名 `对话录屏_<ts>.mov`，与 md / wav 共用同一 `<ts>`、同一 `savePath`。

`finalize` 时 `await recorder.finish()`（与现有 `pendingTranscriptionTask` 同等对待）。

### 5.4 数据流

```
SCStream ──.audio──→ audioBuffer.appendSystem ─┐
AVAudioEngine ─────→ audioBuffer.appendMic ────┤→ mixAudio → mixed ─┬→ WAV 存档（保留）
                                               │                    ├→ ASR → markdown
SCStream ──.screen──→ MeetingScreenRecorder ───┤                    └→ recorder.appendAudio
                         AVAssetWriter ←─ 视频帧 + mixed 音频 ───────┘→ 对话录屏_<ts>.mov
```

音视频同步：writer session 以第一帧 `.complete` 视频帧 PTS 为 t0；音频 PTS 按累计采样数推算。长会议存在亚 100ms 漂移，对会议存档可接受。

## 6. 错误处理（ASR 优先，录屏永不拖垮会议）

| 情况 | 行为 |
|------|------|
| 屏幕录制权限被拒 | `SCStream` 本就创建失败 → 无录屏。沿用现有「系统音频未采集」markdown 警告，文案补一句录屏也未启用 |
| `AVAssetWriter` 启动失败 | recorder 自废，会议照常；记日志 |
| 录屏中途写帧失败 | recorder 置 `failed`、停止接收，会议照常 |
| WAV 写失败 | 维持现状逻辑，与录屏无关 |

## 7. 文件清理

| 场景 | 处理 |
|------|------|
| 空会议（`MeetingService` 现有删 md + wav 处） | 一并删 `.mov` |
| 会议被取消（双 Command 触发） | `recorder.cancel()`，删半成品 `.mov` |
| 过期自动清理 — `HistoryTab.pruneOldFiles()` | **扩展名白名单从 `md`/`wav` 增加 `mov`**（否则最大的录屏文件永不过期清理） |

## 8. UI — `MeetingTab`

在开始会议控件附近增加一个开关：

- 标题「会议录屏」
- 副标题小字「默认录制主显示器全屏」
- 绑定 `configManager.meetingScreenRecording`
- 会议进行中**禁用并置灰**（中途改不生效，UI 上明确表达）

`.mov` 不在 `HistoryTab` 列表单独成行——`scanFiles()` 维持只列 `.md`，录屏文件靠 `<ts>` 与 markdown 关联（与 `.wav` 现状一致）。

## 9. 不在本次范围

- 重新转写仍从 WAV 读音频，**不改动** `MeetingRetranscriber` / `MeetingRetranscribeLauncher`（WAV 始终保留，无需从 `.mov` 抽音轨）。
- 不做窗口级 / 多显示器选择，只录主显示器全屏。
- 不做录屏文件的应用内回放，双击交由系统播放器。
