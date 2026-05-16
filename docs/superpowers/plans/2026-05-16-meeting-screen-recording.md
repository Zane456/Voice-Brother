# 会议录屏功能 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给会议/对话录制增加屏幕录制：开启后会议全程录下主显示器全屏，连同麦克风+系统音写成一个 `.mov` 视频文件，与现有 markdown、WAV 一起保存。

**Architecture:** 复用现有 `SCStream`（目前只采系统音频）多配一路 `.screen` 视频输出。新增 `MeetingScreenRecorder` 封装 `AVAssetWriter`：视频帧来自 SCStream，音频复用 `MeetingService` 录制循环已混好的那路采样。录屏失败自废，永不拖垮会议。WAV 始终保留，不碰重新转写逻辑。

**Tech Stack:** Swift / SwiftUI / AppKit / ScreenCaptureKit / AVFoundation，macOS 14+ 应用。

**设计文档：** `docs/superpowers/specs/2026-05-16-meeting-screen-recording-design.md`

**重要 — 无单元测试 target：** 本工程只有 `VoiceBubble` 一个 target，没有测试 target。每个任务的验证手段是 `xcodebuild build` 编译通过（exit 0）。功能行为的验收在最后一个任务通过构建+重启+人工核对完成。

**构建命令（每个任务用）：**
```bash
cd "~/IDE project/Voice Bubble"
xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet
```
Expected: 命令退出码 0，无报错输出。

---

## Task 1: 新增配置项 `meetingScreenRecording`

**Files:**
- Modify: `VoiceBubble/Shared/AppConfig.swift`
- Modify: `VoiceBubble/Backend/Services/ConfigManager.swift`

- [ ] **Step 1: AppConfig 加 `@Published` 属性**

在 `AppConfig.swift` 中，`lastHistoryKind` 属性块（以 `@Published var lastHistoryKind: String {` 开头，到其 `}` 结束）之后插入：

```swift
    /// When true, meetings additionally record the main display to a .mov
    /// video file (with mixed mic + system audio). Off by default.
    @Published var meetingScreenRecording: Bool {
        didSet { scheduleSave() }
    }
```

- [ ] **Step 2: AppConfig 加默认值**

在 `static let defaultLastHistoryKind = "voice"` 这一行之后插入：

```swift
    static let defaultMeetingScreenRecording = false
```

- [ ] **Step 3: AppConfig init 里加载**

在 `init()` 中，`self.lastHistoryKind = Self.load("lastHistoryKind", default: Self.defaultLastHistoryKind)` 这一行之后插入：

```swift
        self.meetingScreenRecording = Self.load("meetingScreenRecording", default: Self.defaultMeetingScreenRecording)
```

- [ ] **Step 4: AppConfig performSave 里持久化**

在 `performSave()` 中，`defaults.set(lastHistoryKind, forKey: "lastHistoryKind")` 这一行之后插入：

```swift
        defaults.set(meetingScreenRecording, forKey: "meetingScreenRecording")
```

- [ ] **Step 5: ConfigManager 加转发属性**

在 `ConfigManager.swift` 中，`lastHistoryKind` 转发属性块（以 `var lastHistoryKind: String {` 开头到其 `}`）之后插入：

```swift
    var meetingScreenRecording: Bool {
        get { appConfig.meetingScreenRecording }
        set { appConfig.meetingScreenRecording = newValue }
    }
```

- [ ] **Step 6: 构建验证**

Run: `xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet`
Expected: exit 0。

- [ ] **Step 7: 提交**

```bash
cd "~/IDE project/Voice Bubble"
git add VoiceBubble/Shared/AppConfig.swift VoiceBubble/Backend/Services/ConfigManager.swift
git commit -m "feat(config): add meetingScreenRecording flag"
```

---

## Task 2: 新建 `MeetingScreenRecorder.swift`

**Files:**
- Create: `VoiceBubble/Backend/Meeting/MeetingScreenRecorder.swift`
- Modify: `VoiceBubble.xcodeproj/project.pbxproj`

- [ ] **Step 1: 创建 `MeetingScreenRecorder.swift`**

写入文件 `VoiceBubble/Backend/Meeting/MeetingScreenRecorder.swift`，完整内容：

```swift
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Records the screen to a `.mov` file for the duration of a meeting.
///
/// Owns an `AVAssetWriter` with two inputs:
/// - video, fed by the `.screen` sample buffers of the meeting's `SCStream`
/// - audio (AAC), fed by the mixed mic + system samples that `MeetingService`
///   already produces for its WAV archive and ASR
///
/// Every operation is serialized on `outputQueue`, which is also the
/// `sampleHandlerQueue` registered for the `.screen` stream output. On any
/// failure the recorder sets `failed` and silently drops the rest — screen
/// recording must never break the meeting itself.
final class MeetingScreenRecorder: NSObject, @unchecked Sendable {

    /// Serial queue: SCStream `.screen` callbacks land here directly, and
    /// `start` / `appendAudio` / `finish` / `cancel` all hop onto it. Passed
    /// to `SCStream.addStreamOutput(_:type:sampleHandlerQueue:)` by the caller.
    let outputQueue = DispatchQueue(label: "com.voicebubble.screenrecorder")

    /// 16 kHz — the rate of the mixed audio `MeetingService` hands us.
    private static let audioSampleRate: Int32 = 16000

    private let outputURL: URL

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?

    /// PTS of the first complete video frame; the writer session starts here
    /// and audio timestamps are derived relative to it.
    private var firstVideoPTS: CMTime = .invalid
    /// True once `startSession` has been called (on the first complete frame).
    private var sessionStarted = false
    /// Set on any unrecoverable error — all further appends are dropped.
    private var failed = false
    /// Running count of audio sample frames appended, for deriving audio PTS.
    private var audioSampleCursor: Int64 = 0

    init(outputURL: URL) {
        self.outputURL = outputURL
        super.init()
    }

    // MARK: - Lifecycle

    /// Build and start the `AVAssetWriter`. `displaySize` is the pixel size of
    /// the video track (matches the `SCStreamConfiguration` width/height).
    /// Called before the stream output is registered, so the writer is ready
    /// by the time the first frame arrives.
    func start(displaySize: CGSize) {
        outputQueue.async {
            do {
                try? FileManager.default.removeItem(at: self.outputURL)
                let writer = try AVAssetWriter(outputURL: self.outputURL, fileType: .mov)

                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: Int(displaySize.width),
                    AVVideoHeightKey: Int(displaySize.height),
                ]
                let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                videoInput.expectsMediaDataInRealTime = true

                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: Int(Self.audioSampleRate),
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 32000,
                ]
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioInput.expectsMediaDataInRealTime = true

                guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
                    throw NSError(domain: "MeetingScreenRecorder", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "AVAssetWriter cannot add inputs"
                    ])
                }
                writer.add(videoInput)
                writer.add(audioInput)

                guard writer.startWriting() else {
                    throw writer.error ?? NSError(domain: "MeetingScreenRecorder", code: 2)
                }

                self.writer = writer
                self.videoInput = videoInput
                self.audioInput = audioInput
            } catch {
                print("[MeetingScreenRecorder] start failed: \(error). Screen recording disabled for this meeting.")
                self.failed = true
            }
        }
    }

    /// Finalize the `.mov`. Returns true only if a usable file was written.
    /// On failure (or if no video frame ever arrived) the partial file is
    /// deleted. Awaited by `MeetingService` during meeting finalization.
    @discardableResult
    func finish() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            outputQueue.async {
                guard let writer = self.writer, self.sessionStarted, !self.failed else {
                    self.writer?.cancelWriting()
                    try? FileManager.default.removeItem(at: self.outputURL)
                    continuation.resume(returning: false)
                    return
                }
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                writer.finishWriting {
                    let ok = writer.status == .completed
                    if !ok {
                        try? FileManager.default.removeItem(at: self.outputURL)
                    }
                    continuation.resume(returning: ok)
                }
            }
        }
    }

    /// Abort recording and delete any partial file. Used for empty meetings
    /// and error paths.
    func cancel() {
        outputQueue.async {
            self.failed = true
            if let writer = self.writer, writer.status == .writing {
                writer.cancelWriting()
            }
            try? FileManager.default.removeItem(at: self.outputURL)
        }
    }

    // MARK: - Audio

    /// Append a chunk of mixed mono 16 kHz float samples. Called from
    /// `MeetingService`'s recording loop. Dropped until the video session has
    /// started (so audio shares the video timeline).
    func appendAudio(_ samples: [Float]) {
        outputQueue.async {
            guard !self.failed, self.sessionStarted,
                  let audioInput = self.audioInput,
                  !samples.isEmpty else { return }
            guard let sampleBuffer = self.makeAudioSampleBuffer(samples) else { return }
            guard audioInput.isReadyForMoreMediaData else { return }
            if !audioInput.append(sampleBuffer) {
                print("[MeetingScreenRecorder] audio append failed: \(String(describing: self.writer?.error))")
                self.failed = true
            }
        }
    }

    /// Build an LPCM (float32 mono) `CMSampleBuffer` for the given samples.
    /// PTS is `firstVideoPTS + audioSampleCursor / 16000`; the cursor advances
    /// even if the buffer is later dropped, so timing never drifts.
    private func makeAudioSampleBuffer(_ samples: [Float]) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(Self.audioSampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        ) == noErr, let formatDesc else { return nil }

        let pts = CMTimeAdd(
            firstVideoPTS,
            CMTime(value: audioSampleCursor, timescale: Self.audioSampleRate)
        )
        audioSampleCursor += Int64(samples.count)

        let byteCount = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else { return nil }

        let copyOK = samples.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            ) == noErr
        }
        guard copyOK else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Self.audioSampleRate),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleSize = MemoryLayout<Float>.size
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: samples.count,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }

        return sampleBuffer
    }
}

// MARK: - SCStreamOutput (video frames)

extension MeetingScreenRecorder: @preconcurrency SCStreamOutput {
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        // Runs on `outputQueue` (registered as the sampleHandlerQueue).
        guard type == .screen, !failed,
              let writer = writer, let videoInput = videoInput else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer), isComplete(sampleBuffer) else { return }

        if !sessionStarted {
            firstVideoPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: firstVideoPTS)
            sessionStarted = true
        }

        guard videoInput.isReadyForMoreMediaData else { return }
        if !videoInput.append(sampleBuffer) {
            print("[MeetingScreenRecorder] video append failed: \(String(describing: writer.error))")
            failed = true
        }
    }

    /// A `.screen` sample buffer is only safe to write when its frame status
    /// attachment is `.complete` (idle/blank frames carry no pixels).
    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let attachments = array.first,
              let raw = attachments[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }
}
```

- [ ] **Step 2: 在 project.pbxproj 注册 build file 条目**

本工程的 `.xcodeproj` 不使用 file-system-synchronized group，新文件必须手动登记 4 处。本步用到两个固定 ID：`FA11C0DE5C8EE001A0000001`（PBXBuildFile）、`FA11C0DE5C8EE001A0000002`（PBXFileReference）。

在 `VoiceBubble.xcodeproj/project.pbxproj` 中，找到这一行：

```
		0CC6DE6C1FB6BE084ABA5ECA /* MeetingService.swift in Sources */ = {isa = PBXBuildFile; fileRef = 78C2DF426A804646C9F98185 /* MeetingService.swift */; };
```

在它**之后**插入一行：

```
		FA11C0DE5C8EE001A0000001 /* MeetingScreenRecorder.swift in Sources */ = {isa = PBXBuildFile; fileRef = FA11C0DE5C8EE001A0000002 /* MeetingScreenRecorder.swift */; };
```

- [ ] **Step 3: 注册 PBXFileReference 条目**

找到这一行：

```
		78C2DF426A804646C9F98185 /* MeetingService.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MeetingService.swift; sourceTree = "<group>"; };
```

在它**之后**插入一行：

```
		FA11C0DE5C8EE001A0000002 /* MeetingScreenRecorder.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MeetingScreenRecorder.swift; sourceTree = "<group>"; };
```

- [ ] **Step 4: 加入 Meeting group 的 children**

找到 Meeting group 里的这一行：

```
				78C2DF426A804646C9F98185 /* MeetingService.swift */,
```

在它**之后**插入一行：

```
				FA11C0DE5C8EE001A0000002 /* MeetingScreenRecorder.swift */,
```

- [ ] **Step 5: 加入 Sources build phase**

找到 Sources build phase 里的这一行：

```
				0CC6DE6C1FB6BE084ABA5ECA /* MeetingService.swift in Sources */,
```

在它**之后**插入一行：

```
				FA11C0DE5C8EE001A0000001 /* MeetingScreenRecorder.swift in Sources */,
```

- [ ] **Step 6: 构建验证**

Run: `xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet`
Expected: exit 0。新文件已纳入编译。

> 若编译报 `kAudioFormatLinearPCM` / `kAudioFormatFlagIsFloat` 等常量未找到，在 `MeetingScreenRecorder.swift` 顶部补 `import AudioToolbox`。
> 若编译报 `MeetingScreenRecorder` 不满足 `Sendable`（`addStreamOutput` 处），确认类声明保留了 `@unchecked Sendable`。

- [ ] **Step 7: 提交**

```bash
cd "~/IDE project/Voice Bubble"
git add VoiceBubble/Backend/Meeting/MeetingScreenRecorder.swift VoiceBubble.xcodeproj/project.pbxproj
git commit -m "feat(meeting): add MeetingScreenRecorder (AVAssetWriter wrapper)"
```

---

## Task 3: 把录屏接入 `MeetingService`

**Files:**
- Modify: `VoiceBubble/Backend/Meeting/MeetingService.swift`

- [ ] **Step 1: 新增 `screenRecorder` 与 `videoFilePath` 属性**

找到 `scStream` 属性声明：

```swift
    private var scStream: SCStream?
```

在它**之后**插入：

```swift
    /// Screen recorder for the current meeting — non-nil only while a meeting
    /// with screen recording enabled is in progress.
    private var screenRecorder: MeetingScreenRecorder?
```

找到 `audioFilePath` 属性声明：

```swift
    private var audioFilePath: String?
```

在它**之后**插入：

```swift
    /// Absolute path of the screen-recording `.mov` for the current meeting.
    /// Set in `initMarkdown` alongside the markdown/WAV paths so all three
    /// share one timestamp; the recorder is only created if screen recording
    /// is enabled.
    private var videoFilePath: String?
```

- [ ] **Step 2: 在 `initMarkdown` 计算 `.mov` 路径**

找到 `initMarkdown()` 中这三行：

```swift
        let audioFilename = "对话录音_\(ts).wav"
        let audioPath = (savePath as NSString).appendingPathComponent(audioFilename)
        audioFilePath = audioPath
```

在它们**之后**插入：

```swift
        // Screen recording (if enabled) writes a .mov alongside, sharing the
        // same timestamp so the three files of one meeting group together.
        let videoFilename = "对话录屏_\(ts).mov"
        videoFilePath = (savePath as NSString).appendingPathComponent(videoFilename)
```

- [ ] **Step 3: 新增显示器尺寸换算静态方法**

在 `MeetingService` 类内，`mixAudio` 方法之后（或任意方法之间）插入：

```swift
    /// Pixel size for the screen-recording video: the display's aspect ratio
    /// with height capped at 1080, both dimensions rounded to even numbers
    /// (H.264 requires even width/height).
    private static func screenRecordingSize(displayWidth: Int, displayHeight: Int) -> CGSize {
        guard displayWidth > 0, displayHeight > 0 else {
            return CGSize(width: 1920, height: 1080)
        }
        let cappedHeight = min(displayHeight, 1080)
        let aspect = Double(displayWidth) / Double(displayHeight)
        var h = cappedHeight
        var w = Int((Double(h) * aspect).rounded())
        if w % 2 != 0 { w += 1 }
        if h % 2 != 0 { h += 1 }
        return CGSize(width: w, height: h)
    }
```

- [ ] **Step 4: 改写 SCStream 配置块，挂上视频输出**

找到 `runRecording()` 中这整段（从注释 `// Start system audio capture` 到 `systemAudioCaptured` 的 markdown 警告写入）：

```swift
        // Start system audio capture via ScreenCaptureKit. If this fails (e.g. user
        // didn't grant screen recording permission) we record mic-only and surface
        // that fact in the markdown header so the user isn't surprised later.
        var systemAudioCaptured = false
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                throw NSError(domain: "MeetingService", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "未找到显示器"
                ])
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = Int(Self.sckSampleRate)
            config.channelCount = 1

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "sysaudio"))
            try await stream.startCapture()
            self.scStream = stream
            systemAudioCaptured = true
        } catch {
            print("[MeetingService] System audio capture failed: \(error). Continuing with microphone only.")
        }

        if !systemAudioCaptured {
            writeToFile("> ⚠️ 系统音频未能采集（可能未授予屏幕录制权限），本次记录仅采集麦克风。\n\n")
        }
```

整段替换为：

```swift
        // Snapshot the screen-recording preference once for this meeting — the
        // UI toggle is disabled while a meeting runs, so this can't change.
        let screenRecordingEnabled = configManager.meetingScreenRecording

        // Start system audio capture via ScreenCaptureKit. If this fails (e.g. user
        // didn't grant screen recording permission) we record mic-only and surface
        // that fact in the markdown header so the user isn't surprised later.
        // When screen recording is on, the same SCStream also emits video frames
        // into a MeetingScreenRecorder.
        var systemAudioCaptured = false
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                throw NSError(domain: "MeetingService", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "未找到显示器"
                ])
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = Int(Self.sckSampleRate)
            config.channelCount = 1

            // Screen recording: configure the same stream to also emit video,
            // downscaled to ≤1080p at 10fps to keep the .mov archive small.
            if screenRecordingEnabled, let videoPath = videoFilePath {
                let videoSize = Self.screenRecordingSize(
                    displayWidth: display.width,
                    displayHeight: display.height
                )
                config.width = Int(videoSize.width)
                config.height = Int(videoSize.height)
                config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                let recorder = MeetingScreenRecorder(outputURL: URL(fileURLWithPath: videoPath))
                recorder.start(displaySize: videoSize)
                self.screenRecorder = recorder
            }

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "sysaudio"))
            if let recorder = self.screenRecorder {
                try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.outputQueue)
            }
            try await stream.startCapture()
            self.scStream = stream
            systemAudioCaptured = true
        } catch {
            print("[MeetingService] System audio capture failed: \(error). Continuing with microphone only.")
            // The stream never started — discard the recorder so its empty
            // .mov file doesn't linger.
            self.screenRecorder?.cancel()
            self.screenRecorder = nil
        }

        if !systemAudioCaptured {
            if screenRecordingEnabled {
                writeToFile("> ⚠️ 系统音频与屏幕录制未能启用（可能未授予屏幕录制权限），本次记录仅采集麦克风。\n\n")
            } else {
                writeToFile("> ⚠️ 系统音频未能采集（可能未授予屏幕录制权限），本次记录仅采集麦克风。\n\n")
            }
        }
```

- [ ] **Step 5: 在混音循环把音频喂给录屏器**

找到 `runRecording()` 录制循环里这一段：

```swift
            if let mixed = mixAudio(sysChunks: currentSys, micChunks: currentMic), !mixed.isEmpty {
                accumulated.append(contentsOf: mixed)
                // Stream the same mixed samples to the WAV file. Doing it here
                // means the archive audio is always exactly what ASR heard —
                // if the user later replays the recording and something was
                // misrecognised they can hear exactly what the mic picked up.
                appendAudioSamples(mixed)
            }
```

替换为：

```swift
            if let mixed = mixAudio(sysChunks: currentSys, micChunks: currentMic), !mixed.isEmpty {
                accumulated.append(contentsOf: mixed)
                // Stream the same mixed samples to the WAV file. Doing it here
                // means the archive audio is always exactly what ASR heard —
                // if the user later replays the recording and something was
                // misrecognised they can hear exactly what the mic picked up.
                appendAudioSamples(mixed)
                // The screen recording reuses this exact mix as its audio track.
                screenRecorder?.appendAudio(mixed)
            }
```

- [ ] **Step 6: 在 `runRecording` 收尾处终结录屏**

找到 `runRecording()` 收尾段里的这一行（紧接在 `let isEmptyMeeting = transcribedSegmentCount == 0` 注释段之后、`audioFile = nil` 之前）：

```swift
        let isEmptyMeeting = transcribedSegmentCount == 0
```

在它**之后**插入：

```swift

        // Finalize the screen recording before touching files. An empty meeting
        // discards the .mov along with the markdown/WAV; otherwise await the
        // writer so the .mov is fully flushed.
        if let recorder = screenRecorder {
            if isEmptyMeeting {
                recorder.cancel()
            } else {
                _ = await recorder.finish()
            }
            screenRecorder = nil
        }
```

- [ ] **Step 7: 在 `cleanup()` 错误路径取消录屏**

找到 `cleanup()` 中的 scStream 停止段：

```swift
        if let stream = scStream {
            try? await stream.stopCapture()
            scStream = nil
        }
```

在它**之后**插入：

```swift
        // Error path — discard any in-progress screen recording.
        screenRecorder?.cancel()
        screenRecorder = nil
```

- [ ] **Step 8: 构建验证**

Run: `xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet`
Expected: exit 0。

- [ ] **Step 9: 提交**

```bash
cd "~/IDE project/Voice Bubble"
git add VoiceBubble/Backend/Meeting/MeetingService.swift
git commit -m "feat(meeting): wire screen recording into MeetingService"
```

---

## Task 4: 过期清理纳入 `.mov`

**Files:**
- Modify: `VoiceBubble/Frontend/Tabs/HistoryTab.swift`

- [ ] **Step 1: `pruneOldFiles` 扩展名白名单加 `mov`**

找到 `pruneOldFiles()` 中这一行：

```swift
            guard ext == "md" || ext == "wav" else { continue }
```

替换为：

```swift
            guard ext == "md" || ext == "wav" || ext == "mov" else { continue }
```

- [ ] **Step 2: 构建验证**

Run: `xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet`
Expected: exit 0。

- [ ] **Step 3: 提交**

```bash
cd "~/IDE project/Voice Bubble"
git add VoiceBubble/Frontend/Tabs/HistoryTab.swift
git commit -m "feat(history): prune old screen-recording .mov files"
```

---

## Task 5: MeetingTab 录屏开关

**Files:**
- Modify: `VoiceBubble/Frontend/Tabs/MeetingTab.swift`

- [ ] **Step 1: 在 body 插入录屏开关卡片**

找到 `body` 中 `ScrollView` 内的这段：

```swift
                VStack(alignment: .leading, spacing: 24) {
                    recordingControlCard
                    openFolderButton
```

替换为：

```swift
                VStack(alignment: .leading, spacing: 24) {
                    recordingControlCard
                    screenRecordingToggleCard
                    openFolderButton
```

- [ ] **Step 2: 新增 `screenRecordingToggleCard`**

在 `openFolderButton` 计算属性的结束 `}` 之后插入：

```swift
    /// 会议录屏 开关。录屏配置持久化在设置里，但开关直接放在录制控件下方，
    /// 方便临场决定。会议进行中禁用——录屏开关在会议开始时读一次快照。
    private var screenRecordingToggleCard: some View {
        let meetingActive: Bool = {
            switch meetingService.state {
            case .idle, .error: return false
            default: return true
            }
        }()

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("会议录屏")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.textPrimary)
                Text("开启后会议全程录制主显示器全屏，存为视频文件")
                    .font(.system(size: 11))
                    .foregroundColor(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $configManager.meetingScreenRecording)
                .toggleStyle(CustomToggleStyle())
                .labelsHidden()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .disabled(meetingActive)
        .opacity(meetingActive ? 0.5 : 1)
    }
```

- [ ] **Step 3: 构建验证**

Run: `xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet`
Expected: exit 0。

- [ ] **Step 4: 提交**

```bash
cd "~/IDE project/Voice Bubble"
git add VoiceBubble/Frontend/Tabs/MeetingTab.swift
git commit -m "feat(meeting): add screen recording toggle to MeetingTab"
```

---

## Task 6: 构建、重启、人工验收

**Files:** 无（验收任务）

- [ ] **Step 1: 构建并重启应用**

```bash
cd "~/IDE project/Voice Bubble"
xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet
pkill -x "VoiceBubble" 2>/dev/null || true
open "~/Library/Developer/Xcode/DerivedData/VoiceBubble-arbvxvbxxsnfymbulsnszkqkgdon/Build/Products/Debug/VoiceBubble.app"
```
Expected: 构建 exit 0，应用启动。

- [ ] **Step 2: 人工验收清单**

在 对话记录 页确认：
1. 「会议录屏」开关出现在录制控件下方，带小字说明，默认 **关**。
2. 打开开关 → 开始一场会议 → 录制控件下方的开关变灰禁用。
3. 说几句话、切换几个窗口 → 停止记录。
4. 打开对话记录文件夹，确认出现三个同时间戳文件：`对话记录_<ts>.md`、`对话录音_<ts>.wav`、`对话录屏_<ts>.mov`。
5. 双击 `.mov`，系统播放器能播放，画面是主显示器全屏，**有声音**（麦克风 + 系统音）。
6. 关闭「会议录屏」开关 → 再开一场会议 → 文件夹里这次只有 `.md` + `.wav`，无 `.mov`。

> 注：首次开启录屏若此前从未授予屏幕录制权限，会议采集会失败并在 markdown 写警告；按 `PermissionManager` 的重启横幅授权并重启后再试。

- [ ] **Step 3: （如有问题）记录并回到对应 Task 修复**

若验收某项失败，定位到相关 Task 修正后重新走 Step 1。

---

## 完成标准

- 6 个 Task 全部 `xcodebuild build` exit 0。
- Task 6 人工验收 6 项全部通过。
- 录屏关闭时行为与改动前完全一致（只有 `.md` + `.wav`）。
