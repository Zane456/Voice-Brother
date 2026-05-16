# Apple SFSpeechRecognizer Integration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Apple's built-in SFSpeechRecognizer as a third local ASR model option (device-only offline), alongside two existing Qwen3 MLX models.

**Architecture:** Introduce `ASREngineProtocol` to unify ASR engines behind a common interface. VoiceService and MeetingService store `(any ASREngineProtocol)?` instead of `Qwen3ASRModel?`. Two implementations: `QwenASREngine` (wraps existing Qwen3ASRModel) and `AppleASREngine` (wraps SFSpeechRecognizer with on-device recognition).

**Tech Stack:** Swift, SFSpeechRecognizer (Speech framework), existing Qwen3ASR (MLX), SwiftUI

**Spec:** `docs/superpowers/specs/2026-04-04-apple-asr-integration-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `VoiceBubble/Shared/Protocols.swift` | Modify | Add `ASREngineProtocol` |
| `VoiceBubble/Shared/Types.swift` | Modify | Add `.apple` case to `ASRModel` enum |
| `VoiceBubble/Backend/Voice/QwenASREngine.swift` | Create | Thin wrapper around `Qwen3ASRModel` |
| `VoiceBubble/Backend/Voice/AppleASREngine.swift` | Create | SFSpeechRecognizer wrapper with WAV file + semaphore |
| `VoiceBubble/Backend/Voice/VoiceService.swift` | Modify | Replace `asrModel` with `asrEngine`, branch start() |
| `VoiceBubble/Backend/Meeting/MeetingService.swift` | Modify | Replace `asrModel` with `asrEngine`, Task.detached for transcribe |
| `VoiceBubble/Frontend/Tabs/Sections/VoiceSettingsSection.swift` | Modify | Conditional UI for Apple model |
| `VoiceBubble/Info.plist` | Modify | Add `NSSpeechRecognitionUsageDescription` |
| `project.yml` | Modify | Add Speech framework dependency |

---

### Task 1: ASREngineProtocol + ASRModel enum

**Files:**
- Modify: `VoiceBubble/Shared/Protocols.swift:80` (append after existing protocols)
- Modify: `VoiceBubble/Shared/Types.swift:140-180` (ASRModel enum)

- [ ] **Step 1: Add ASREngineProtocol to Protocols.swift**

Append at end of file:

```swift
// MARK: - ASR Engine Protocol

protocol ASREngineProtocol: AnyObject {
    /// Returns transcribed text, or empty string on failure. Non-throwing — wrappers handle errors internally.
    func transcribe(audio: [Float], sampleRate: Int, language: String, context: String?) -> String
    func unload()
}
```

- [ ] **Step 2: Add `.apple` case to ASRModel enum in Types.swift**

The enum is at line 140. Add the new case and update all computed properties:

```swift
enum ASRModel: String, CaseIterable, Identifiable {
    case small = "Qwen/Qwen3-ASR-0.6B"
    case large = "Qwen/Qwen3-ASR-1.7B"
    case apple = "apple_speech"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: return "0.6B 极速模式"
        case .large: return "1.7B 精确模式"
        case .apple: return "Apple 语音识别"
        }
    }

    var huggingFaceId: String {
        switch self {
        case .small: return "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
        case .large: return "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
        case .apple: return ""
        }
    }

    var estimatedSize: String {
        switch self {
        case .small: return "~400MB"
        case .large: return "~2.5GB"
        case .apple: return "系统内置"
        }
    }

    var fullName: String {
        switch self {
        case .small: return "Qwen3-ASR-0.6B"
        case .large: return "Qwen3-ASR-1.7B"
        case .apple: return "Apple Speech"
        }
    }

    var quantization: String {
        switch self {
        case .small: return "MLX 4bit"
        case .large: return "MLX 8bit"
        case .apple: return "Neural Engine"
        }
    }

    var isApple: Bool { self == .apple }
    var isQwen: Bool { !isApple }
}
```

- [ ] **Step 3: Build to verify no regressions (expect exhaustive-switch errors)**

Run: `cd "~/IDE project/Voice Bubble" && xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet 2>&1 | head -30`

Expected: Compiler errors in `VoiceService.swift` for non-exhaustive switch on `ASRModel`. This is correct — we'll fix them in Task 4.

- [ ] **Step 4: Commit**

```bash
git add VoiceBubble/Shared/Protocols.swift VoiceBubble/Shared/Types.swift
git commit -m "feat: add ASREngineProtocol and Apple case to ASRModel enum"
```

---

### Task 2: QwenASREngine wrapper

**Files:**
- Create: `VoiceBubble/Backend/Voice/QwenASREngine.swift`

- [ ] **Step 1: Create QwenASREngine.swift**

```swift
import Foundation
import Qwen3ASR

/// Thin wrapper around Qwen3ASRModel conforming to ASREngineProtocol.
final class QwenASREngine: ASREngineProtocol {
    private let model: Qwen3ASRModel

    init(model: Qwen3ASRModel) {
        self.model = model
    }

    func transcribe(audio: [Float], sampleRate: Int, language: String, context: String?) -> String {
        do {
            return try model.transcribe(
                audio: audio,
                sampleRate: sampleRate,
                language: language,
                context: context
            )
        } catch {
            NSLog("[QwenASREngine] Transcription failed: %@", error.localizedDescription)
            return ""
        }
    }

    func unload() {
        model.unload()
    }
}
```

Note: Wrap in do/catch because `Qwen3ASRModel.transcribe()` may throw. The protocol contract returns `""` on failure.

- [ ] **Step 2: Commit**

```bash
git add VoiceBubble/Backend/Voice/QwenASREngine.swift
git commit -m "feat: add QwenASREngine wrapper for ASREngineProtocol"
```

---

### Task 3: AppleASREngine wrapper

**Files:**
- Create: `VoiceBubble/Backend/Voice/AppleASREngine.swift`

- [ ] **Step 1: Create AppleASREngine.swift**

```swift
import Foundation
import Speech

/// Apple SFSpeechRecognizer wrapper conforming to ASREngineProtocol.
/// On-device only recognition. Failable init — returns nil if on-device recognition is not supported.
/// IMPORTANT: transcribe() blocks the calling thread with a semaphore. Must be called from a background thread (Task.detached).
final class AppleASREngine: ASREngineProtocol {
    private let recognizer: SFSpeechRecognizer
    private let tempFileURL: URL

    /// Failable init. Returns nil if on-device recognition is not supported (e.g. Intel Mac, language model not downloaded).
    init?() {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-Hans")) else {
            NSLog("[AppleASREngine] Failed to create SFSpeechRecognizer for zh-Hans")
            return nil
        }
        guard recognizer.supportsOnDeviceRecognition else {
            NSLog("[AppleASREngine] On-device recognition not supported")
            return nil
        }
        self.recognizer = recognizer
        self.tempFileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vb_apple_asr_temp.wav")
    }

    func transcribe(audio: [Float], sampleRate: Int, language: String, context: String?) -> String {
        // 1. Write audio to temporary WAV file
        guard writeWAV(samples: audio, sampleRate: sampleRate) else {
            NSLog("[AppleASREngine] Failed to write temporary WAV file")
            return ""
        }
        defer { try? FileManager.default.removeItem(at: tempFileURL) }

        // 2. Create recognition request
        let request = SFSpeechURLRecognitionRequest(url: tempFileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        // 3. Run recognition with semaphore (blocking — must be called from background thread)
        let semaphore = DispatchSemaphore(value: 0)
        var resultText = ""

        var signaled = false
        recognizer.recognitionTask(with: request) { result, error in
            if let error {
                NSLog("[AppleASREngine] Recognition error: %@", error.localizedDescription)
            }
            if let result, result.isFinal {
                resultText = result.bestTranscription.formattedString
            }
            // Signal exactly once — callback may fire multiple times (partial + final + error)
            if result?.isFinal == true || error != nil {
                guard !signaled else { return }
                signaled = true
                semaphore.signal()
            }
        }

        let timeout = DispatchTime.now() + .seconds(30)
        if semaphore.wait(timeout: timeout) == .timedOut {
            NSLog("[AppleASREngine] Recognition timed out after 30s")
            return ""
        }

        return resultText
    }

    func unload() {
        // No-op — system manages SFSpeechRecognizer lifecycle
    }

    // MARK: - WAV File Writing

    /// Write Float32 audio samples as 16-bit PCM WAV file.
    private func writeWAV(samples: [Float], sampleRate: Int) -> Bool {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * Int(bitsPerSample / 8))
        let fileSize = 36 + dataSize

        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(littleEndian: fileSize)
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(littleEndian: UInt32(16))          // chunk size
        data.append(littleEndian: UInt16(1))           // PCM format
        data.append(littleEndian: numChannels)
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: byteRate)
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: bitsPerSample)

        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(littleEndian: dataSize)

        // Convert Float32 [-1.0, 1.0] to Int16
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16Value = Int16(clamped * Float(Int16.max))
            data.append(littleEndian: int16Value)
        }

        do {
            try data.write(to: tempFileURL)
            return true
        } catch {
            NSLog("[AppleASREngine] Failed to write WAV: %@", error.localizedDescription)
            return false
        }
    }
}

// MARK: - Data Extension for Little-Endian Writing

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var le = value.littleEndian
        append(UnsafeBufferPointer(start: &le, count: 1))
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add VoiceBubble/Backend/Voice/AppleASREngine.swift
git commit -m "feat: add AppleASREngine with on-device SFSpeechRecognizer"
```

---

### Task 4: Migrate VoiceService to ASREngineProtocol

**Files:**
- Modify: `VoiceBubble/Backend/Voice/VoiceService.swift`

This is the largest task. Changes are surgical — replace `asrModel` references with `asrEngine` and branch `start()` for Apple vs Qwen.

- [ ] **Step 1: Add `import Speech` at top of file**

Add after the existing imports (around line 6):
```swift
import Speech
```

- [ ] **Step 2: Replace asrModel property with asrEngine**

At line 31, change:
```swift
private(set) var asrModel: Qwen3ASRModel?
```
to:
```swift
private(set) var asrEngine: (any ASREngineProtocol)?
```

At line 827-829, after `keyboardListenerRef`, add:
```swift

/// Expose the ASR engine for MeetingService to borrow.
var asrEngineRef: (any ASREngineProtocol)? {
    asrEngine
}
```

- [ ] **Step 3: Rewrite start() to branch on model type**

Replace the existing `start()` method (lines 138-184) with:

```swift
func start() {
    guard state.isIdle else { return }

    Task { @MainActor in
        do {
            // 1. Check permissions
            guard AXIsProcessTrusted() else {
                state = .error("需要辅助功能权限")
                return
            }
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                state = .error("需要麦克风权限")
                return
            }

            // 2. Determine model
            let modelString = configManager.model
            let selectedModel = ASRModel(rawValue: modelString) ?? .large

            if selectedModel.isApple {
                // Apple ASR path: request authorization, then create engine
                try await startAppleASR()
            } else {
                // Qwen path: download + load model
                try await startQwenASR(model: selectedModel)
            }

        } catch {
            state = .error("启动失败: \(error.localizedDescription)")
        }
    }
}

private func startAppleASR() async throws {
    // Request speech recognition authorization
    let authStatus = await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { status in
            continuation.resume(returning: status)
        }
    }
    guard authStatus == .authorized else {
        state = .error("需要语音识别权限")
        return
    }

    state = .loading
    guard let engine = AppleASREngine() else {
        state = .error("此设备不支持 Apple 离线语音识别")
        return
    }

    self.asrEngine = engine
    state = .ready
    startKeyboardListener()
    // No alternate model download for Apple
}

private func startQwenASR(model: ASRModel) async throws {
    let hfId = model.huggingFaceId

    state = .downloading
    let qwenModel = try await Qwen3ASRModel.fromPretrained(
        modelId: hfId,
        progressHandler: { [weak self] progress, status in
            Task { @MainActor in
                self?.handleDownloadProgress(progress: progress, status: status)
            }
        }
    )

    guard !Task.isCancelled else { return }

    self.asrEngine = QwenASREngine(model: qwenModel)
    state = .ready
    startKeyboardListener()
    downloadAlternateModel(current: model)
}
```

- [ ] **Step 4: Update stop() to use asrEngine**

At line 206-210, change:
```swift
// Unload ASR model
if let model = asrModel {
    model.unload()
    asrModel = nil
}
```
to:
```swift
// Unload ASR engine
asrEngine?.unload()
asrEngine = nil
```

- [ ] **Step 5: Update transcribeAndInject() to use asrEngine**

At line 525-528, change:
```swift
guard let model = asrModel else {
    state = .error("模型未加载")
    return
}
```
to:
```swift
guard let engine = asrEngine else {
    state = .error("模型未加载")
    return
}
```

At lines 556-564, change the transcription call:
```swift
let capturedContext = context.isEmpty ? nil : context
let text = await Task.detached {
    model.transcribe(
        audio: allSamples,
        sampleRate: 16000,
        language: "Chinese",
        context: capturedContext
    )
}.value
```
to:
```swift
let capturedContext = context.isEmpty ? nil : context
let text = await Task.detached { [engine] in
    engine.transcribe(
        audio: allSamples,
        sampleRate: 16000,
        language: "Chinese",
        context: capturedContext
    )
}.value
```

- [ ] **Step 6: Update runPreviewTranscription() to use asrEngine**

At line 403, change:
```swift
guard isRecording, let model = asrModel, !isPreviewTranscribing else { return }
```
to:
```swift
guard isRecording, let engine = asrEngine, !isPreviewTranscribing else { return }
```

Replace the entire `Task.detached` block (lines 420-434) with:

```swift
Task.detached { [weak self, engine] in
    let text = engine.transcribe(
        audio: samples,
        sampleRate: 16000,
        language: "Chinese",
        context: context.isEmpty ? nil : context
    )
    await MainActor.run {
        guard let self else { return }
        self.isPreviewTranscribing = false
        if !text.isEmpty {
            RecordingOverlayPanel.shared.updateStreamingText(text)
        }
    }
}
```

Note: Protocol is non-throwing so `try?` is replaced with direct call. Empty string is the failure signal.

- [ ] **Step 7: Update downloadAlternateModel() for Apple case**

At line 733-757, change the method to handle `.apple`:

```swift
private func downloadAlternateModel(current: ASRModel) {
    // No alternate download for Apple ASR
    guard current.isQwen else { return }

    let alternateModel: ASRModel = (current == .small) ? .large : .small
    let alternateHfId = alternateModel.huggingFaceId

    backgroundDownloadTask = Task {
        do {
            _ = try await Qwen3ASRModel.fromPretrained(
                modelId: alternateHfId,
                progressHandler: { _, _ in }
            )
        } catch {
            print("[VoiceService] Background download of alternate model failed: \(error)")
        }
    }
}
```

- [ ] **Step 8: Update handleDownloadProgress() for Apple case**

At line 720-729, the method uses `ASRModel(rawValue:)` in a switch. Update:

```swift
private func handleDownloadProgress(progress: Double, status: String) {
    let currentModel = ASRModel(rawValue: configManager.model) ?? .large
    let approxTotal: Int64
    switch currentModel {
    case .small: approxTotal = 400_000_000
    case .large: approxTotal = 2_500_000_000
    case .apple: return  // Apple has no download step
    }
    let downloaded = Int64(progress * Double(approxTotal))
    downloadProgress = DownloadProgress(
        downloaded: downloaded,
        total: approxTotal,
        description: status
    )
}
```

- [ ] **Step 9: Remove resolveHuggingFaceId() helper**

This method (lines 811-816) is no longer needed — `start()` now branches directly. Delete it.

- [ ] **Step 10: Build to check for remaining compile errors**

Run: `cd "~/IDE project/Voice Bubble" && xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet 2>&1 | head -40`

Expected: May still have errors in MeetingService (fixed in Task 5). VoiceService should compile cleanly.

- [ ] **Step 11: Commit**

```bash
git add VoiceBubble/Backend/Voice/VoiceService.swift
git commit -m "feat: migrate VoiceService from Qwen3ASRModel to ASREngineProtocol"
```

---

### Task 5: Migrate MeetingService to ASREngineProtocol

**Files:**
- Modify: `VoiceBubble/Backend/Meeting/MeetingService.swift`

- [ ] **Step 1: Replace asrModel property and import**

Remove `import Qwen3ASR` from the imports (line 5).

At line 41, change:
```swift
private var asrModel: Qwen3ASRModel?
```
to:
```swift
private var asrEngine: (any ASREngineProtocol)?
```

- [ ] **Step 2: Update start() to use asrEngineRef**

At lines 98-105, change:
```swift
// Share the already-loaded model from voice service (no reload needed).
// Safe because voice recording is suppressed during meetings (meetingActive = true).
guard let asr = self.voiceService?.asrModel else {
    self.state = .error("语音服务未加载模型")
    self.voiceService?.keyboardListenerRef?.isMeetingActive = false
    RecordingOverlayPanel.shared.hide()
    return
}
self.asrModel = asr
```
to:
```swift
// Share the already-loaded engine from voice service (no reload needed).
// Safe because voice recording is suppressed during meetings (meetingActive = true).
guard let engine = self.voiceService?.asrEngineRef else {
    self.state = .error("语音服务未加载模型")
    self.voiceService?.keyboardListenerRef?.isMeetingActive = false
    RecordingOverlayPanel.shared.hide()
    return
}
self.asrEngine = engine
```

- [ ] **Step 3: Update transcribeSegment() with Task.detached**

Replace the entire method (lines 532-549):

```swift
private func transcribeSegment(_ audio: [Float], timestamp: Date) {
    guard let engine = asrEngine else {
        appendSegment(timestamp: timestamp, text: "[转写失败：模型未加载]")
        return
    }

    // Must use Task.detached to avoid blocking MainActor.
    // Critical for AppleASREngine (semaphore deadlock), also improves Qwen (no main thread blocking).
    let capturedAudio = audio
    let sampleRate = Int(Self.sampleRate)

    Task.detached { [weak self] in
        let text = engine.transcribe(
            audio: capturedAudio,
            sampleRate: sampleRate,
            language: "Chinese",
            context: nil
        )
        let processed = TextProcessor.removeFillers(from: text)
        if !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await self?.appendSegment(timestamp: timestamp, text: processed)
        }
    }
}
```

- [ ] **Step 4: Update cleanup and runRecording release**

In `cleanup()` (around line 566), change:
```swift
asrModel = nil  // Don't unload — shared with voice service
```
to:
```swift
asrEngine = nil  // Don't unload — shared with voice service
```

In `runRecording()` (around line 415), same change:
```swift
// Release model references (don't unload — ASR model is shared with voice service)
asrModel = nil
```
to:
```swift
// Release engine reference (don't unload — shared with voice service)
asrEngine = nil
```

Also in the early return guard (around line 113):
```swift
self.asrModel = nil  // Don't unload — shared with voice service
```
to:
```swift
self.asrEngine = nil  // Don't unload — shared with voice service
```

- [ ] **Step 5: Build and verify**

Run: `cd "~/IDE project/Voice Bubble" && xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet 2>&1 | tail -5`

Expected: Clean build (0 errors).

- [ ] **Step 6: Commit**

```bash
git add VoiceBubble/Backend/Meeting/MeetingService.swift
git commit -m "feat: migrate MeetingService from Qwen3ASRModel to ASREngineProtocol"
```

---

### Task 6: Info.plist + project.yml + Speech framework

**Files:**
- Modify: `VoiceBubble/Info.plist`
- Modify: `project.yml`

- [ ] **Step 1: Add speech recognition usage description to Info.plist**

Add before the closing `</dict>`:

```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>Voice Bubble 需要语音识别权限来使用 Apple 内置语音识别</string>
```

- [ ] **Step 2: Add Speech framework and permission key to project.yml**

In the `dependencies` section of the VoiceBubble target, add:

```yaml
      - sdk: Speech.framework
```

Also add to `OTHER_LDFLAGS`:
```yaml
OTHER_LDFLAGS: ["-framework", "ScreenCaptureKit", "-framework", "Speech"]
```

Also add to `info: properties:` section (around line 68):
```yaml
        NSSpeechRecognitionUsageDescription: "Voice Bubble 需要语音识别权限来使用 Apple 内置语音识别"
```

This ensures xcodegen regeneration preserves the permission key.

- [ ] **Step 3: Regenerate xcodeproj if using xcodegen**

Check if xcodegen is used:
```bash
which xcodegen && xcodegen generate
```

If xcodegen is not installed, the project.yml changes are informational — the xcodeproj needs manual sync (add new .swift files and Speech framework in Xcode, or the source glob in project.yml auto-picks them up since `sources: - path: VoiceBubble` includes all files).

- [ ] **Step 4: Build and verify**

Run: `cd "~/IDE project/Voice Bubble" && xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet 2>&1 | tail -5`

Expected: Clean build.

- [ ] **Step 5: Commit**

```bash
git add VoiceBubble/Info.plist project.yml
git commit -m "feat: add Speech framework and NSSpeechRecognitionUsageDescription"
```

---

### Task 7: VoiceSettingsSection UI for Apple model

**Files:**
- Modify: `VoiceBubble/Frontend/Tabs/Sections/VoiceSettingsSection.swift`

- [ ] **Step 1: Update localASRContent for Apple model conditional display**

The `localASRContent` view (line 80-179) needs conditional logic. Replace the model info section and hint text.

In the `HStack` with model info tags (around line 98-101), wrap in a conditional:

```swift
if let currentModel = ASRModel(rawValue: configManager.model), currentModel.isQwen {
    modelInfoTag(icon: "cpu", text: currentModel.quantization)
    modelInfoTag(icon: "internaldrive", text: currentModel.estimatedSize)
} else if let currentModel = ASRModel(rawValue: configManager.model), currentModel.isApple {
    modelInfoTag(icon: "apple.logo", text: currentModel.quantization)
    modelInfoTag(icon: "checkmark.circle", text: currentModel.estimatedSize)
}
```

For the HuggingFace ID row (lines 110-119), wrap in a conditional to only show for Qwen:

```swift
if let currentModel = ASRModel(rawValue: configManager.model), currentModel.isQwen {
    HStack {
        Text("")
            .frame(width: 66)
        Text(currentModel.huggingFaceId)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(Color(hex: "8AA0BE"))
        Spacer()
    }
}
```

For the hint text at line 176, make it conditional:

```swift
if let currentModel = ASRModel(rawValue: configManager.model), currentModel.isApple {
    Text("无需下载，使用系统内置语音识别引擎")
        .font(.system(size: 12))
        .foregroundColor(Color(hex: "5A7098"))
} else {
    Text("首次启动需下载模型（约 400MB），下载完成后自动加载")
        .font(.system(size: 12))
        .foregroundColor(Color(hex: "5A7098"))
}
```

- [ ] **Step 2: Build and verify**

Run: `cd "~/IDE project/Voice Bubble" && xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet 2>&1 | tail -5`

Expected: Clean build.

- [ ] **Step 3: Commit**

```bash
git add VoiceBubble/Frontend/Tabs/Sections/VoiceSettingsSection.swift
git commit -m "feat: update VoiceSettingsSection UI for Apple ASR model option"
```

---

### Task 8: Final build, restart, and manual test

- [ ] **Step 1: Full clean build**

```bash
cd "~/IDE project/Voice Bubble"
xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet
```

- [ ] **Step 2: Restart app**

```bash
pkill -x "VoiceBubble" 2>/dev/null || true
open "~/Library/Developer/Xcode/DerivedData/VoiceBubble-arbvxvbxxsnfymbulsnszkqkgdon/Build/Products/Debug/VoiceBubble.app"
```

- [ ] **Step 3: Manual verification checklist**

1. Open Settings → 语音设置 → 语音识别模型
2. Verify 3 options in Picker: Qwen3-ASR-0.6B, Qwen3-ASR-1.7B, Apple Speech
3. Select "Apple Speech" → verify info tags show "Neural Engine" and "系统内置"
4. Verify HuggingFace ID row is hidden
5. Verify hint text says "无需下载，使用系统内置语音识别引擎"
6. Click "启动" → should request speech recognition permission
7. Grant permission → status should show "模型已加载"
8. Test voice input with Apple ASR (hold trigger key, speak, release)
9. Switch back to Qwen model → verify it still works (download + load)
