# Apple SFSpeechRecognizer Integration

Add Apple's built-in speech recognition as a third local ASR model option alongside Qwen3-ASR-0.6B and Qwen3-ASR-1.7B. Device-only offline mode, no server fallback.

## Architecture: ASREngineProtocol

Unify all ASR engines behind a shared protocol. VoiceService and MeetingService store `(any ASREngineProtocol)?` instead of `Qwen3ASRModel?`.

```swift
protocol ASREngineProtocol: AnyObject {
    /// Returns transcribed text, or empty string on failure. Non-throwing — wrappers handle errors internally.
    func transcribe(audio: [Float], sampleRate: Int, language: String, context: String?) -> String
    func unload()
}
```

**Error contract**: `transcribe()` returns `""` on any failure (network error, auth denied, model error). Non-throwing keeps call sites simple. Wrappers log errors internally via `NSLog`.

### QwenASREngine

Thin wrapper around `Qwen3ASRModel`. Forwards `transcribe()` and `unload()` directly.

File: `Backend/Voice/QwenASREngine.swift`

### AppleASREngine

Wraps `SFSpeechRecognizer` with on-device-only recognition.

File: `Backend/Voice/AppleASREngine.swift`

Key implementation details:

- **Init**: `SFSpeechRecognizer(locale: Locale(identifier: "zh-Hans"))`. Failable init — returns nil if `supportsOnDeviceRecognition == false` (e.g. Intel Macs, language not downloaded). Caller checks and shows error.
- **transcribe()**: Convert `[Float]` → temporary WAV file in `NSTemporaryDirectory()` (fixed path, overwritten each call) → `SFSpeechURLRecognitionRequest` with `requiresOnDeviceRecognition = true` → wait with `DispatchSemaphore` → return text → delete temp file. Returns `""` on any error.
- **Semaphore safety**: All callers **must** invoke from background thread (`Task.detached`). MeetingService.transcribeSegment must be wrapped in `Task.detached` (mandatory, not optional).
- **context parameter**: Ignored (SFSpeechRecognizer doesn't support hotwords)
- **language parameter**: Ignored (locale set at init time to zh-Hans)
- **unload()**: No-op (system manages lifecycle)
- **WAV format**: 16-bit PCM, mono, with standard 44-byte RIFF/WAVE header. Sample rate from caller parameter.

## ASRModel Enum Changes

Add third case to `Types.swift`:

```swift
enum ASRModel: String, CaseIterable, Identifiable {
    case small = "Qwen/Qwen3-ASR-0.6B"
    case large = "Qwen/Qwen3-ASR-1.7B"
    case apple = "apple_speech"
}
```

Apple-specific properties:
- `displayName`: "Apple 语音识别"
- `fullName`: "Apple Speech"
- `estimatedSize`: "系统内置"
- `quantization`: "Neural Engine"
- `huggingFaceId`: `""` (not applicable)

Add `var isApple: Bool` and `var isQwen: Bool` helpers.

## VoiceService Changes

- `asrModel: Qwen3ASRModel?` → `asrEngine: (any ASREngineProtocol)?`
- `start()`: Branch on model selection:
  - Qwen: download + load via `Qwen3ASRModel.fromPretrained()` → wrap in `QwenASREngine`
  - Apple: Create `AppleASREngine` directly → skip `.downloading` state, go straight to `.ready`
- `transcribeAndInject()`: Use `asrEngine.transcribe()` via protocol
- `runPreviewTranscription()`: Same — use protocol
- `downloadAlternateModel()`: Only run for Qwen models (skip when Apple selected)
- `resolveHuggingFaceId()`: Return empty for Apple (not used in Apple path)

### MeetingService access pattern

Currently `voiceService?.asrModel` is typed as `Qwen3ASRModel?`. Change to expose `asrEngine`:

```swift
// VoiceService
var asrEngineRef: (any ASREngineProtocol)? { asrEngine }
```

MeetingService borrows via `voiceService?.asrEngineRef`.

## MeetingService Changes

- `asrModel: Qwen3ASRModel?` → `asrEngine: (any ASREngineProtocol)?`
- `start()`: Borrow `voiceService?.asrEngineRef` instead of `voiceService?.asrModel`
- `transcribeSegment()`: **Must** wrap in `Task.detached` — mandatory to avoid MainActor deadlock with Apple's semaphore-based engine. Also improves Qwen (stops blocking main thread during meeting transcription).
- Remove `import Qwen3ASR` (protocol is sufficient)

## VoiceSettingsSection Changes

The Picker already iterates `ASRModel.allCases`. Adding `.apple` to the enum auto-adds it to the picker.

Conditional display when Apple is selected:
- Hide HuggingFace ID row
- Show "Neural Engine" for quantization, "系统内置" for size
- Change download hint text to "无需下载，使用系统内置语音识别引擎"
- Download progress bar: never shown (no download step)

## Permissions

- Add `NSSpeechRecognitionUsageDescription` to Info.plist: "Voice Bubble 需要语音识别权限来使用 Apple 内置语音识别"
- **Authorization sequence** (mandatory order):
  1. `VoiceService.start()` detects Apple model selected
  2. Call `SFSpeechRecognizer.requestAuthorization()` and `await` result **before** creating `AppleASREngine`
  3. If `.authorized` → create engine → `.ready`
  4. If denied/restricted → `state = .error("需要语音识别权限")`, do not create engine
- This avoids deadlock: auth dialog is async and must complete before the semaphore-based transcribe() is ever called

## Compiler Safety

Adding `.apple` to `ASRModel` enum will trigger exhaustive-switch errors. Key locations that need updating:
- `VoiceService.downloadAlternateModel()` — add `case .apple: return` (no alternate download)
- `VoiceService.handleDownloadProgress()` — add Apple case (never called, but compiler requires it)
- Any other switch on `ASRModel` — handle `.apple` explicitly

## Files Changed

| File | Change |
|------|--------|
| `Shared/Types.swift` | Add `.apple` case to `ASRModel` |
| `Shared/Protocols.swift` | Add `ASREngineProtocol` |
| `Backend/Voice/QwenASREngine.swift` | **New** — Qwen wrapper |
| `Backend/Voice/AppleASREngine.swift` | **New** — Apple wrapper |
| `Backend/Voice/VoiceService.swift` | `asrModel` → `asrEngine`, branch in `start()` |
| `Backend/Meeting/MeetingService.swift` | `asrModel` → `asrEngine`, use protocol |
| `Frontend/Tabs/Sections/VoiceSettingsSection.swift` | Conditional UI for Apple model |
| `project.yml` / `VoiceBubble.xcodeproj` | Add new files, Speech framework |
| Info.plist | Add `NSSpeechRecognitionUsageDescription` |

## Not in scope

- Adding Apple ASR to cloud model picker (it's local only)
- Language selection UI (hardcoded zh-Hans, same as Qwen's "Chinese")
- Streaming preview changes (protocol handles it transparently)
