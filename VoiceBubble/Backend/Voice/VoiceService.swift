import AVFoundation
import AppKit
import AudioCommon
import AudioToolbox
import Combine
import CoreAudio
import CoreGraphics
import Foundation
import Qwen3ASR
import Qwen3Chat
import Speech

/// Main voice input lifecycle service.
/// Manages ASR model loading, audio recording, transcription, and text injection.
@MainActor
final class VoiceService: ObservableObject, VoiceServiceProtocol {

    // MARK: - Published State

    @Published var state: ServiceState = .stopped
    @Published var downloadProgress: DownloadProgress?
    @Published var removeFillers: Bool
    @Published var spaceReposition: Bool

    // MARK: - Dependencies

    private let configManager: ConfigManager
    private let historyStore = HistoryStore()

    /// Callback to toggle meeting recording, set by the app after MeetingService is created.
    var meetingToggleAction: (() -> Void)?

    // MARK: - Internal State

    private(set) var asrEngine: (any ASREngineProtocol)?
    private(set) var chatModel: Qwen3ChatModel?
    @Published var chatModelReady = false
    @Published var chatModelDownloadProgress: DownloadProgress?
    @Published var chatModelLoading = false
    private var keyboardListener: KeyboardListener?
    private var audioEngine: AVAudioEngine?

    /// Audio buffer protected by a lock for thread-safe access from audio tap callback.
    private var _audioChunks: [Data] = []
    private let audioLock = NSLock()

    /// Recording flag protected by a lock for thread-safe access from audio tap callback.
    private var _isRecording = false
    private let isRecordingLock = NSLock()

    /// Thread-safe getter/setter for isRecording.
    private var isRecording: Bool {
        get { isRecordingLock.withLock { _isRecording } }
        set { isRecordingLock.withLock { _isRecording = newValue } }
    }

    /// True between key release and the actual mic-engine stop. The audio tap
    /// keeps appending samples (so we capture the user's trailing syllables)
    /// but the overlay's waveform is frozen — visually the recording feels
    /// "done" the instant the user lets go, while ASR sees an extra ~400 ms
    /// of audio. Read from the audio tap callback, so it's lock-protected.
    private var _isCapturingTail = false
    private let isCapturingTailLock = NSLock()
    private var isCapturingTail: Bool {
        get { isCapturingTailLock.withLock { _isCapturingTail } }
        set { isCapturingTailLock.withLock { _isCapturingTail = newValue } }
    }

    /// Tail-capture window, in milliseconds. Tuned for the typical 200–400 ms
    /// release-to-silence gap of casual speech.
    private static let tailCaptureMillis: UInt64 = 400

    /// Diagnostic: count of audio tap callbacks received during current recording.
    private var tapFireCount: Int = 0

    /// Thread-safe swap of audioChunks, returning current contents.
    private func swapAudioChunks() -> [Data] {
        audioLock.lock()
        defer { audioLock.unlock() }
        let chunks = _audioChunks
        _audioChunks = []
        return chunks
    }

    /// Thread-safe append to audioChunks.
    private func appendAudioChunk(_ data: Data) {
        audioLock.lock()
        _audioChunks.append(data)
        audioLock.unlock()
    }

    /// Thread-safe clear audioChunks.
    private func clearAudioChunks() {
        audioLock.lock()
        _audioChunks = []
        audioLock.unlock()
    }

    /// Thread-safe copy of audioChunks (without clearing).
    private func readAudioChunks() -> [Data] {
        audioLock.lock()
        defer { audioLock.unlock() }
        return Array(_audioChunks)
    }

    /// Merge audio chunk Data into Float array, skipping initial samples to avoid key press bleed.
    /// For very short recordings, scales the skip down proportionally instead of skipping
    /// the entire buffer (which would leave the leading key-press noise in place).
    private func mergeAudioSamples(from chunks: [Data]) -> [Float] {
        var allSamples: [Float] = []
        for chunk in chunks {
            let count = chunk.count / MemoryLayout<Float>.size
            chunk.withUnsafeBytes { rawBufferPointer in
                if let baseAddress = rawBufferPointer.baseAddress {
                    let floatPtr = baseAddress.assumingMemoryBound(to: Float.self)
                    allSamples.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: count))
                }
            }
        }
        // Skip the leading key-press noise, but protect short utterances. Below
        // 1.0s of audio total, skip nothing at all — single-syllable words like
        // "好"/"嗯"/"对"/"OK" can land in the 0.15–0.6s range and we want every
        // sample reaching ASR. Above 1.0s we strip the full 100ms, which still
        // leaves ≥0.9s of real speech for the model.
        let minRetainSamples = 16_000  // 1.0s @ 16kHz
        let maxSkip = max(0, allSamples.count - minRetainSamples)
        let actualSkip = min(skipSamples, maxSkip)
        if actualSkip > 0 {
            allSamples = Array(allSamples.dropFirst(actualSkip))
        }
        return allSamples
    }

    /// Timestamp when recording started, used to compute duration for history.
    private var recordingStartTime: Date?

    /// Safety timer to auto-stop recording after 120 seconds.
    private var safetyTimer: Timer?

    /// Timer for periodic streaming preview transcription.
    private var previewTimer: Timer?

    /// Fires once ~1.2s into a recording to verify the audio tap actually
    /// received a buffer. If `tapFireCount` is still 0 at that point the
    /// mic is almost certainly held exclusively by another app (WeChat /
    /// 钉钉 / 飞书 call, Claude voice, etc.) — we abort the recording and
    /// surface a visible message instead of silently collecting zero bytes.
    private var audioHealthCheckTimer: Timer?

    /// Fast-recovery timer: fires well before the health check's hard abort. If no
    /// tap callback has fired by then, we rebuild the engine ONCE (e.g. WeChat had
    /// the device in VoIP mode at recording start, AVAudioEngine latched onto a
    /// stale format). One retry — if it fails too, the health check still aborts.
    private var audioRecoveryTimer: Timer?

    /// Per-recording flag so the fast-recovery rebuild only runs once.
    private var audioRecoveryAttempted = false

    /// Observer for `AVAudioEngineConfigurationChange`. Fires when the underlying
    /// audio device's config changes — typically when another app (WeChat, Zoom,
    /// etc.) ends a call and the system flips the input device back to its default
    /// sample rate. AVAudioEngine stops itself when this happens; we rebuild so
    /// the user's in-progress recording survives the transition.
    private var audioConfigChangeObserver: NSObjectProtocol?

    /// Guard flag to prevent concurrent model access between preview and final transcription.
    private var isPreviewTranscribing = false

    /// Tracks in-flight transcription/finalize work so we can await completion
    /// before yielding the shared ASR engine to the meeting service. The engine
    /// is not thread-safe; running voice and meeting transcribe concurrently
    /// on the same model will corrupt results or crash.
    private var pendingASRTask: Task<Void, Never>?

    /// Snapshot of streaming preview setting at recording start (avoids mid-recording toggle issues).
    private var currentRecordingStreamingPreview = false

    // Self-learning feedback
    private var pendingFeedback: FeedbackCollector.PendingFeedback?
    private var feedbackExpiryTimer: Timer?
    private let correctionStore = CorrectionStore()

    /// Number of audio samples to skip at the start of recording — purely to trim
    /// the leading "key press click" noise that bleeds into the audio tap.
    ///
    /// Built-in mic: 400ms is enough to mask the held-key sound and any analog
    /// click captured by a sensitive built-in array.
    ///
    /// Bluetooth: 0. The SCO warm-up window (which used to be where leading
    /// garbage came from) is now handled by the `hasReceivedRealAudio` gate in
    /// the audio tap — anything before the first non-silent buffer is discarded
    /// at capture time. A *post-tap* skip on top of that just chops off real
    /// speech the user already said. This was the bug behind "前几个字识别不上".
    private var skipSamples: Int {
        // Built-in: 100ms (was 400ms — too aggressive; fn / modifier triggers don't
        // make a click sound, so 400ms was eating real speech from the user's first
        // 1–2 characters). Bluetooth: 0 (gated by hasReceivedRealAudio elsewhere).
        Self.isCurrentInputBluetooth() ? 0 : 1_600  // 0s vs 0.1s @ 16kHz
    }

    /// How long the audio health check waits before declaring "no buffers received,
    /// mic must be occupied". Bluetooth needs much more slack to allow the SCO link
    /// to finish warming up.
    private var audioHealthCheckTimeout: TimeInterval {
        Self.isCurrentInputBluetooth() ? 4.0 : 1.2
    }

    /// How long to keep the audio engine running after a recording ends. For Bluetooth
    /// we want a generous window so back-to-back recordings reuse the already-warm
    /// SCO link instead of paying the warm-up cost again. For built-in mics this just
    /// reduces engine setup overhead. Set to 0 to disable.
    private var keepAliveAfterRecording: TimeInterval {
        // Built-in bumped from 1.0s → 3.0s so back-to-back presses (e.g. correcting
        // a misrecognized phrase) reuse the warm engine instead of paying full
        // cold-start latency every time.
        Self.isCurrentInputBluetooth() ? 8.0 : 3.0
    }

    /// Pre-warm duration. Bluetooth needs longer to bring the SCO link up cleanly.
    private var prewarmDuration: TimeInterval {
        Self.isCurrentInputBluetooth() ? 1.5 : 0.5
    }

    /// Timer that delays actually shutting down the audio engine after a recording.
    /// Lets back-to-back recordings reuse the warm Bluetooth link.
    private var engineKeepAliveTimer: Timer?

    /// When true, the audio engine is currently running in "keep-alive" mode —
    /// no recording is active, but the engine is held open so the next press can
    /// start instantly. Buffers received during this window are discarded.
    private var engineWarmKept = false

    /// Frontmost app name captured at the moment the trigger key was pressed.
    /// Used as lightweight ASR context so the model knows the domain (IDE vs email vs chat).
    private var recordingAppContext: String?

    // MARK: - Feedback Sounds
    //
    // Why these are stored properties (not `NSSound(named:)?.play()` inline):
    // The inline pattern creates a temporary NSSound that ARC drops as soon as the
    // expression returns. macOS often (but not always) keeps the sound playing via
    // its own retain inside `play()`, but in practice — especially for short clips
    // played in rapid succession — the dealloc races the playback start and the
    // sound is silenced. Holding the instance for the lifetime of the service
    // makes playback reliable. Also: pre-loading from the system .aiff file via
    // file URL is more robust than `NSSound(named:)`, which depends on the sound
    // being registered in the search paths.
    private lazy var startSound: NSSound? = Self.loadSystemSound(named: "Tink")
    private lazy var endSound: NSSound? = Self.loadSystemSound(named: "Pop")

    private static func loadSystemSound(named name: String) -> NSSound? {
        let path = "/System/Library/Sounds/\(name).aiff"
        if FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if let sound = NSSound(contentsOf: url, byReference: true) {
                sound.volume = 0.5
                return sound
            }
        }
        // Fall back to the named lookup (works if the sound is in standard search paths)
        return NSSound(named: NSSound.Name(name))
    }

    /// Plays a short cue when recording starts. Prefers the held NSSound (volume-controlled
    /// and reliable). If that's nil for any reason — sound file missing, audio device contention —
    /// falls back to AudioServicesPlaySystemSoundID, which uses CoreAudio's UI-feedback path
    /// and is harder to silence.
    private func playStartSound() {
        if let sound = startSound {
            if sound.isPlaying { sound.stop() }
            sound.play()
        } else {
            AudioServicesPlaySystemSound(1057) // Tink
        }
    }

    private func playEndSound() {
        if let sound = endSound {
            if sound.isPlaying { sound.stop() }
            sound.play()
        } else {
            AudioServicesPlaySystemSound(1103) // Pop-ish
        }
    }

    init(configManager: ConfigManager) {
        self.configManager = configManager
        self.removeFillers = configManager.removeFillers
        self.spaceReposition = configManager.spaceReposition
    }

    // MARK: - VoiceServiceProtocol

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

                // 2. Branch: cloud vs local
                if configManager.asrProviderType == "cloud" {
                    try await startCloudASR()
                } else {
                    let modelString = configManager.model
                    let selectedModel = ASRModel(rawValue: modelString) ?? .large

                    if selectedModel.isApple {
                        try await startAppleASR()
                    } else {
                        try await startQwenASR(model: selectedModel)
                    }
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

        // Detect the very common "language asset not installed" case up front. The Speech
        // framework will silently return empty strings if the zh-Hans on-device asset is
        // missing — we'd rather tell the user exactly where to go than leave them puzzled
        // by transcripts that always come back blank.
        if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-Hans")),
           !recognizer.isAvailable {
            state = .error("中文语音模型未就绪，请在「系统设置 → 键盘 → 听写」中添加中文（简体）后重试")
            return
        }

        self.asrEngine = engine
        state = .ready
        startKeyboardListener()
        prewarmAudioEngine()
    }

    private func startQwenASR(model: ASRModel) async throws {
        let hfId = model.huggingFaceId

        state = .downloading
        let t0 = Date()
        debugLog("startQwenASR begin: model=\(hfId)")
        let qwenModel = try await Qwen3ASRModel.fromPretrained(
            modelId: hfId,
            progressHandler: { [weak self] progress, status in
                Task { @MainActor in
                    self?.handleDownloadProgress(progress: progress, status: status)
                }
            }
        )
        let elapsed = Date().timeIntervalSince(t0)
        debugLog(String(format: "startQwenASR fromPretrained returned in %.2fs", elapsed))

        guard !Task.isCancelled else { return }

        self.asrEngine = QwenASREngine(model: qwenModel)
        state = .ready
        debugLog("startQwenASR ready (state=.ready)")
        startKeyboardListener()
        prewarmAudioEngine()
        // Note: previously called `prefetchOtherLocalASRModel()` here to
        // pre-download the other size variant (0.6B ↔ 1.7B). Removed because
        // most users never switch and the prefetch costs ~2.5GB of disk plus
        // background bandwidth. If the user does switch, the download happens
        // on demand at switch time. The function below is kept available in
        // case we want to expose it as an opt-in setting later.
    }

    /// After the primary ASR model is loaded, quietly download the *other*
    /// local Qwen3-ASR model's weights to the HF cache so the user can switch
    /// between 0.6B and 1.7B without waiting for a fresh download. Weights
    /// stay on disk only — we don't load them into memory.
    ///
    /// Uses HuggingFaceDownloader's cache-fast-path (PROJECT.md → 外部依赖补丁),
    /// so this is a no-op once both models are cached. Runs in the background
    /// on a detached task so the UI and primary ASR stay responsive.
    private func prefetchOtherLocalASRModel() {
        let currentId = (ASRModel(rawValue: configManager.model) ?? .large).huggingFaceId
        let targets = [ASRModel.small, ASRModel.large]
            .map { $0.huggingFaceId }
            .filter { !$0.isEmpty && $0 != currentId }

        for modelId in targets {
            Task.detached(priority: .background) {
                do {
                    let cacheDir = try HuggingFaceDownloader.getCacheDirectory(for: modelId)
                    try await HuggingFaceDownloader.downloadWeights(
                        modelId: modelId,
                        to: cacheDir,
                        additionalFiles: ["vocab.json", "merges.txt", "tokenizer_config.json"],
                        progressHandler: nil
                    )
                    print("[VoiceService] prefetch complete: \(modelId)")
                } catch {
                    print("[VoiceService] prefetch failed for \(modelId): \(error)")
                }
            }
        }
    }

    private func startCloudASR() async throws {
        guard let provider = CloudASRProvider(rawValue: configManager.cloudASRProvider) else {
            state = .error("未知的云端 ASR 提供商")
            return
        }

        let creds = configManager.cloudASRCredentials[provider.rawValue] ?? ProviderCredentials()

        switch provider {
        case .volcanoASR:
            guard !creds.apiKey.isEmpty, !creds.baseURL.isEmpty else {
                state = .error("请配置 App ID 和 Access Token")
                return
            }
            let engine = VolcanoASREngine(
                appKey: creds.apiKey,
                accessKey: creds.baseURL,
                resourceId: creds.model.isEmpty ? "volc.seedasr.sauc.duration" : creds.model
            )
            self.asrEngine = engine

        case .openaiWhisper, .deepgram:
            state = .error("\(provider.displayName) 暂未实现")
            return
        }

        state = .ready
        startKeyboardListener()
        prewarmAudioEngine()
    }

    func stop() {
        // Cancel safety timer
        safetyTimer?.invalidate()
        safetyTimer = nil

        // Cancel preview timer
        previewTimer?.invalidate()
        previewTimer = nil

        // Cancel audio health check timer
        audioHealthCheckTimer?.invalidate()
        audioHealthCheckTimer = nil
        audioRecoveryTimer?.invalidate()
        audioRecoveryTimer = nil

        // Stop keyboard listener
        keyboardListener?.stop()
        keyboardListener = nil

        // Stop audio engine — service teardown is a hard stop, no keep-alive
        stopAudioEngineImmediately()

        // Unload ASR engine
        asrEngine?.unload()
        asrEngine = nil

        // Unload chat model
        stopChatModel()

        state = .stopped
        downloadProgress = nil
        isRecording = false
    }

    // MARK: - Keyboard Listener Setup

    private func startKeyboardListener() {
        let triggerKeyString = configManager.triggerKey
        let trigger = TriggerKey(rawValue: triggerKeyString) ?? .cmd_r

        let listener = KeyboardListener(
            triggerKey: trigger.keyCode,
            flagMask: trigger.flagMask,
            triggerMouseButton: trigger.mouseButtonNumber,
            onPress: { [weak self] in
                Task { @MainActor in
                    self?.handleKeyPress()
                }
            },
            onRelease: { [weak self] in
                Task { @MainActor in
                    self?.handleKeyRelease()
                }
            },
            onCancel: { [weak self] in
                Task { @MainActor in
                    self?.handleCancel()
                }
            },
            onReposition: { [weak self] in
                Task { @MainActor in
                    self?.handleReposition()
                }
            },
            onMeetingToggle: { [weak self] in
                Task { @MainActor in
                    self?.handleMeetingToggle()
                }
            },
            onEnterPress: { [weak self] in
                Task { @MainActor in
                    self?.handleEnterPress()
                }
            }
        )

        listener.start()
        self.keyboardListener = listener
    }

    // MARK: - Key Event Handlers

    /// Whether cloud streaming is active for the current recording.
    private var isCloudStreaming: Bool {
        (asrEngine as? VolcanoASREngine)?.isStreaming == true
    }

    private func handleKeyPress() {
        guard state == .ready else {
            debugLog("handleKeyPress REJECTED: state=\(state.displayText), expected .ready")
            return
        }

        // Clear any pending feedback from previous injection
        clearPendingFeedback()

        do {
            isRecording = true
            clearAudioChunks()
            tapFireCount = 0
            hasReceivedRealAudio = false  // gate that skips Bluetooth SCO warm-up zeros
            audioRecoveryAttempted = false

            // Start the audio engine FIRST. On Bluetooth the SCO link can take
            // 0.5–1.5s to come up, so every millisecond we save before this call
            // is one millisecond of leading speech we don't lose. The frontmost-app
            // capture below uses NSWorkspace which can take a few ms — we run it
            // AFTER `startAudioEngine` so the SCO handshake starts as early as
            // possible. Frontmost app at "press" vs "press + 5ms" is identical.
            try startAudioEngine()
            recordingAppContext = Self.captureFrontmostAppName(privacyMode: configManager.privacyMode)
            recordingStartTime = Date()
            state = .recording
            debugLog("Recording started successfully, appContext=\(recordingAppContext ?? "nil")")

            // Start cloud streaming if using VolcanoASREngine
            if let volcEngine = asrEngine as? VolcanoASREngine {
                volcEngine.onStreamingUpdate = { [weak self] text in
                    DispatchQueue.main.async {
                        RecordingOverlayPanel.shared.updateStreamingText(text)
                    }
                }
                volcEngine.beginStreaming(sampleRate: 16000, language: "Chinese")
            }

            // Snapshot streaming preview setting for this recording session
            // Cloud streaming provides its own preview via onStreamingUpdate
            currentRecordingStreamingPreview = isCloudStreaming || configManager.streamingPreview
            RecordingOverlayPanel.shared.show(
                streamingEnabled: currentRecordingStreamingPreview,
                fontSize: CGFloat(configManager.previewFontSize)
            )
            playStartSound()

            // Safety timer: auto-stop after 120 seconds
            safetyTimer?.invalidate()
            safetyTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.handleKeyRelease()
                }
            }

            // Audio health check: if no tap callback fired within the device-specific
            // timeout, the mic is occupied by another app. Bluetooth needs a much
            // longer window because AirPods sometimes take 2–3s to surface their
            // first buffer after the SCO link comes up.
            let sessionStart = recordingStartTime
            let healthTimeout = audioHealthCheckTimeout
            audioHealthCheckTimer?.invalidate()
            audioHealthCheckTimer = Timer.scheduledTimer(withTimeInterval: healthTimeout, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.isRecording, self.recordingStartTime == sessionStart else { return }
                    guard self.tapFireCount == 0 else { return }
                    self.debugLog("Audio health check FAILED: tapFireCount=0 after \(healthTimeout)s — aborting, mic likely occupied")
                    self.abortRecordingWithMessage("麦克风无输入，可能被其他 app 占用")
                }
            }

            // Fast-recovery: try rebuilding the engine well before the hard abort.
            // Covers the "started while WeChat was on a call" case — first engine
            // sometimes latches onto a stale VoIP format and gets no samples; a
            // fresh engine after the device settles often picks up cleanly.
            let recoveryDelay = healthTimeout * 0.5
            audioRecoveryTimer?.invalidate()
            audioRecoveryTimer = Timer.scheduledTimer(withTimeInterval: recoveryDelay, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.isRecording, self.recordingStartTime == sessionStart else { return }
                    guard self.tapFireCount == 0, !self.audioRecoveryAttempted else { return }
                    self.attemptAudioEngineRecovery(reason: "no audio after \(recoveryDelay)s")
                }
            }

            // Start streaming preview timer for LOCAL models only (cloud has its own push updates).
            // Apple ASR is excluded: its `transcribe` writes a WAV to disk and runs a fresh
            // SFSpeechURLRecognitionRequest each call, so polling every 1.5s collides with the
            // final transcribe on the same temp file path AND wastes the user's CPU. The
            // overlay will simply show the waveform without live text for Apple.
            let supportsPreview = !(asrEngine is AppleASREngine)
            if !isCloudStreaming && configManager.streamingPreview && supportsPreview {
                previewTimer?.invalidate()
                previewTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.runPreviewTranscription()
                    }
                }
            }
        } catch {
            debugLog("FAILED to start audio engine: \(error)")
            print("[VoiceService] Failed to start audio engine: \(error)")
            // Fully reset state so subsequent key presses can start a new
            // recording. Without this the next handleKeyPress would go through
            // (state == .ready) but handleKeyRelease would be triggered on a
            // stale isRecording=true flag, causing the release path to run on
            // an engine that never started.
            isRecording = false
            recordingAppContext = nil
            tapFireCount = 0
            safetyTimer?.invalidate()
            safetyTimer = nil
            previewTimer?.invalidate()
            previewTimer = nil
            state = .ready
        }
    }

    /// Tear down an in-progress recording and surface a message to the user.
    /// Shared exit path for silent-failure cases (mic occupied, no audio
    /// captured, etc.) — keeps state cleanup in one place so future exits
    /// can't forget to invalidate a timer or leave a stale flag. Uses the
    /// immediate stop path: when something went wrong we don't want to keep
    /// holding the mic open for a "warm" follow-up.
    private func abortRecordingWithMessage(_ message: String) {
        isRecording = false
        safetyTimer?.invalidate(); safetyTimer = nil
        previewTimer?.invalidate(); previewTimer = nil
        audioHealthCheckTimer?.invalidate(); audioHealthCheckTimer = nil
        audioRecoveryTimer?.invalidate(); audioRecoveryTimer = nil
        stopAudioEngineImmediately()
        clearAudioChunks()
        (asrEngine as? VolcanoASREngine)?.cancelStreaming()
        RecordingOverlayPanel.shared.showBriefMessage(message)
        state = .ready
    }

    private func handleKeyRelease() {
        guard isRecording else {
            debugLog("handleKeyRelease REJECTED: isRecording=false (recording never started?)")
            return
        }

        // Visual feedback first: as soon as the user lets go, freeze the
        // waveform and show "识别中…". The mic stays open for a short tail-
        // capture window so trailing syllables aren't clipped.
        RecordingOverlayPanel.shared.markFinalizing()
        isCapturingTail = true

        // Stop the timers immediately — no point doing health checks or
        // streaming previews during the tail.
        safetyTimer?.invalidate()
        safetyTimer = nil
        previewTimer?.invalidate()
        previewTimer = nil
        audioHealthCheckTimer?.invalidate()
        audioHealthCheckTimer = nil
        audioRecoveryTimer?.invalidate()
        audioRecoveryTimer = nil

        // Cloud streaming is its own animal: the audio is already being
        // streamed sample-by-sample, so we just call finishStreaming. The
        // tail-capture trick only helps the local-batch ASR path.
        let isCloudStreaming = (asrEngine as? VolcanoASREngine)?.isStreaming == true

        Task { @MainActor in
            if !isCloudStreaming {
                try? await Task.sleep(nanoseconds: Self.tailCaptureMillis * 1_000_000)
            }
            self.finalizeRecordingAfterTail()
        }
    }

    /// Second half of `handleKeyRelease`: runs after the tail-capture delay.
    /// Stops the engine, swaps chunks, and dispatches the transcription path.
    private func finalizeRecordingAfterTail() {
        // Defensive: if a cancel/meeting-handoff already cleaned up while we
        // were sleeping, bail out so we don't double-process.
        guard isCapturingTail else { return }
        isCapturingTail = false
        isRecording = false

        let chunks = swapAudioChunks()
        let engineRunning = audioEngine?.isRunning ?? false
        stopAudioEngine()
        let recordDuration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        debugLog("finalizeRecordingAfterTail: chunks=\(chunks.count), totalBytes=\(chunks.reduce(0) { $0 + $1.count }), duration=\(String(format: "%.1f", recordDuration))s, tapFired=\(tapFireCount), engineRunning=\(engineRunning), isPreviewTranscribing=\(isPreviewTranscribing)")

        state = .transcribing

        // Cloud streaming: finish and get result immediately (audio already sent)
        if let volcEngine = asrEngine as? VolcanoASREngine, volcEngine.isStreaming {
            pendingASRTask = Task { @MainActor in
                let text = await Task.detached { volcEngine.finishStreaming() }.value
                await self.processAndInject(text: text, chunks: chunks)
            }
        } else {
            pendingASRTask = Task { @MainActor in
                if isPreviewTranscribing {
                    debugLog("Waiting for preview transcription to finish...")
                }
                // Poll at 25ms (vs 5ms) — preview transcription takes hundreds of
                // ms anyway, and 5ms wastes wakeups. Cap the wait at 3s so a stuck
                // preview can't permanently block the final transcription.
                let waitDeadline = Date().addingTimeInterval(3.0)
                while isPreviewTranscribing && Date() < waitDeadline {
                    try? await Task.sleep(for: .milliseconds(25))
                }
                if isPreviewTranscribing {
                    debugLog("Preview transcription wait timed out — proceeding anyway")
                    isPreviewTranscribing = false
                }
                await transcribeAndInject(chunks: chunks)
            }
        }
    }

    private func handleCancel() {
        guard isRecording || state == .recording else { return }
        // Abort any pending tail-capture so the scheduled finalize bails out.
        isCapturingTail = false
        isRecording = false
        safetyTimer?.invalidate()
        safetyTimer = nil
        previewTimer?.invalidate()
        previewTimer = nil
        audioHealthCheckTimer?.invalidate()
        audioHealthCheckTimer = nil
        audioRecoveryTimer?.invalidate()
        audioRecoveryTimer = nil
        // ESC = user wants to bail out; release the mic immediately rather than
        // holding it warm for a hypothetical retry.
        stopAudioEngineImmediately()

        clearAudioChunks()

        // Cancel cloud streaming if active
        (asrEngine as? VolcanoASREngine)?.cancelStreaming()

        RecordingOverlayPanel.shared.hide()
        state = .ready
        print("[VoiceService] Recording cancelled by ESC")
    }

    private func handleReposition() {
        guard spaceReposition else { return }

        // Simulate a mouse click at the current cursor position
        let source = CGEventSource(stateID: .hidSystemState)
        let loc = CGEventTapLocation.cghidEventTap

        // Get current mouse position (NSEvent uses bottom-left origin, CGEvent uses top-left)
        let mousePos = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let cgPoint = CGPoint(x: mousePos.x, y: screenHeight - mousePos.y)

        if let mouseDown = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: cgPoint,
            mouseButton: .left
        ) {
            mouseDown.post(tap: loc)
        }
        if let mouseUp = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: cgPoint,
            mouseButton: .left
        ) {
            mouseUp.post(tap: loc)
        }
    }

    private func handleMeetingToggle() {
        // Cancel any in-progress voice recording (including tail capture)
        if isRecording {
            isCapturingTail = false
            isRecording = false
            previewTimer?.invalidate()
            previewTimer = nil
            audioHealthCheckTimer?.invalidate()
            audioHealthCheckTimer = nil
            audioRecoveryTimer?.invalidate()
            audioRecoveryTimer = nil
            // Meeting handoff: release the mic immediately so MeetingService
            // can grab it without contending with our keep-alive.
            stopAudioEngineImmediately()
            clearAudioChunks()
            RecordingOverlayPanel.shared.hide()
        }
        // Reset state back to ready so meeting can use the service
        if state == .recording || state == .transcribing {
            state = .ready
        }
        // Await any in-flight voice transcription BEFORE yielding the shared
        // ASR engine to the meeting service — running two transcribe calls
        // on the same non-thread-safe model will corrupt state.
        let inflight = pendingASRTask
        pendingASRTask = nil
        Task { @MainActor in
            await inflight?.value
            // Also wait for a preview that was in the middle of running.
            let deadline = Date().addingTimeInterval(2.0)
            while isPreviewTranscribing && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            meetingToggleAction?()
        }
    }

    // MARK: - Streaming Preview

    /// Runs a preview transcription on the current accumulated audio buffer.
    /// Called periodically during recording when streaming preview is enabled.
    private func runPreviewTranscription() {
        guard isRecording, let engine = asrEngine, !isPreviewTranscribing else { return }
        // Apple's engine isn't suited for polling — every call rewrites a WAV and runs
        // a fresh SF recognizer, which both wastes work and collides with the final
        // transcribe over the shared temp file. Caller should already gate this, but
        // we double-check here so accidental future hookups don't reintroduce the bug.
        guard !(engine is AppleASREngine) else { return }

        let chunks = readAudioChunks()
        let samples = mergeAudioSamples(from: chunks)

        // Need at least 1 second of audio for meaningful preview
        guard samples.count >= 16000 else { return }

        // Skip only truly-silent buffers. 0.003 ≈ -50 dB — anything quieter is
        // background hiss / dead mic, anything louder is real (possibly soft) speech.
        // Previously gated at 0.01 (-40 dB), which rejected normal quiet speech.
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        guard rms > 0.003 else { return }

        isPreviewTranscribing = true

        let capturedContext = Self.buildHotwordContext(configManager.hotwords, appName: recordingAppContext)

        Task.detached { [weak self, engine] in
            // nil = auto-detect language. Qwen3-ASR is genuinely multilingual;
            // pinning a language here was an old default from when only Chinese
            // was tested, and it caused Japanese/English speech to be decoded
            // as Mandarin homophones.
            let text = engine.transcribe(
                audio: samples,
                sampleRate: 16000,
                language: nil,
                context: capturedContext
            )
            // Preview runs every 1.5s during recording — by far the heaviest
            // contributor to MLX cache growth in normal use. Reclaim each pass
            // so the cache never balloons mid-recording.
            MLXMemoryGovernor.reclaim()
            await MainActor.run {
                guard let self else { return }
                self.isPreviewTranscribing = false
                if !text.isEmpty {
                    RecordingOverlayPanel.shared.updateStreamingText(text)
                }
            }
        }
    }

    // MARK: - Audio Engine

    /// Pre-warm audio hardware by briefly starting and stopping the engine.
    /// This ensures the first real recording has full audio levels instead of
    /// near-zero samples. Bluetooth gets a longer warm-up because the SCO link
    /// can take >1s to stabilize on AirPods specifically.
    private func prewarmAudioEngine() {
        let isBluetooth = Self.isCurrentInputBluetooth()
        let warmDuration = prewarmDuration
        debugLog("Pre-warming audio engine (\(isBluetooth ? "Bluetooth" : "wired/built-in"), duration=\(warmDuration)s)")
        Task { @MainActor in
            do {
                let engine = AVAudioEngine()
                let inputNode = engine.inputNode
                let format = inputNode.outputFormat(forBus: 0)
                guard format.sampleRate > 0 else { return }

                inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in }
                try engine.start()

                DispatchQueue.main.asyncAfter(deadline: .now() + warmDuration) {
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                }
            } catch {
                debugLog("Audio pre-warm failed (non-fatal): \(error)")
            }
        }
    }

    /// Per-recording flag set the first time the audio tap delivers a non-silent
    /// buffer. Used to discard the leading all-zero buffers that AirPods routinely
    /// emit during the SCO link warm-up — without this, the user's first 0.5–1.5s
    /// of speech ends up indistinguishable from silence and gets eaten by the
    /// silence-hallucination filter.
    private var hasReceivedRealAudio = false

    /// Energy threshold (RMS on the raw buffer) below which we treat the buffer
    /// as "still warming up" and don't yet flip `hasReceivedRealAudio`. Tuned low
    /// (0.001) so it ONLY rejects the truly-zero buffers AirPods emits during
    /// SCO link establishment — production logs show those as RMS = 0.0 exactly.
    /// Anything above this — including very quiet whispers and ambient room
    /// noise — passes through, so we never chop the leading characters of
    /// soft-spoken input.
    private let leadingSilenceRMSThreshold: Float = 0.001

    private func startAudioEngine() throws {
        // Engine reuse path: if a previous recording's keep-alive timer is still
        // holding the engine open (warm SCO link with AirPods, for example), reuse
        // it instead of paying the cold-start cost again.
        if let existing = audioEngine, existing.isRunning {
            engineKeepAliveTimer?.invalidate()
            engineKeepAliveTimer = nil
            engineWarmKept = false
            hasReceivedRealAudio = false
            debugLog("Reusing warm audio engine (keep-alive hit) — skipping cold start")
            return
        }

        // Belt-and-suspenders: if engineKeepAliveTimer fired but audioEngine is
        // somehow still around, tear it down before building a fresh one.
        stopAudioEngineImmediately()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        let format = inputNode.outputFormat(forBus: 0)
        debugLog("Audio format: sampleRate=\(format.sampleRate), channels=\(format.channelCount), bits=\(format.streamDescription.pointee.mBitsPerChannel), bluetooth=\(Self.isCurrentInputBluetooth())")

        // Validate format — on macOS cold start, sampleRate can be 0
        guard format.sampleRate > 0, format.channelCount > 0 else {
            debugLog("Invalid audio format! sampleRate=\(format.sampleRate), channels=\(format.channelCount)")
            throw NSError(domain: "VoiceService", code: -1, userInfo: [NSLocalizedDescriptionKey: "麦克风格式无效 (sampleRate=\(format.sampleRate))"])
        }

        // We need 16kHz mono Float32 for the ASR model
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
            debugLog("Failed to create audio converter from \(format) to \(targetFormat)")
            throw NSError(domain: "VoiceService", code: -2, userInfo: [NSLocalizedDescriptionKey: "音频格式转换器创建失败"])
        }

        // Capture targetFormat and converter for the tap closure
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.tapFireCount += 1
            guard self.isRecording else { return }

            // Compute RMS audio level from raw buffer for waveform animation + leading-silence detection
            var rawRMS: Float = 0
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frameLength {
                    sum += channelData[i] * channelData[i]
                }
                rawRMS = sqrtf(sum / Float(max(frameLength, 1)))
                let dB = 20 * log10(max(rawRMS, 1e-6))
                let normalized = max(Float(0), min(Float(1), (dB + 50) / 40))
                // Freeze the waveform the moment the user releases the key,
                // even though we keep capturing audio for the tail window.
                // The user's "I'm done" gesture should produce immediate
                // visual feedback regardless of how long ASR takes.
                if !self.isCapturingTail {
                    DispatchQueue.main.async {
                        RecordingOverlayPanel.shared.updateAudioLevel(normalized)
                    }
                }
            }

            // Bluetooth (AirPods) warm-up workaround: SCO link routinely emits
            // 0.5–1.5s of all-zero buffers before real audio shows up. Skip those
            // — once we've heard real audio, every subsequent buffer (including
            // mid-sentence pauses) is appended normally so we don't truncate
            // silences inside the user's speech.
            if !self.hasReceivedRealAudio {
                if rawRMS < self.leadingSilenceRMSThreshold {
                    return
                }
                self.hasReceivedRealAudio = true
            }

            // Convert to 16kHz mono Float32
            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / format.sampleRate)
            // Skip empty buffers — allocating with capacity 1 would yield an
            // unusable buffer whose floatChannelData pointer can't be safely read.
            guard frameCount > 0 else { return }
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: frameCount
            ) else {
                DebugLog.write("[VoiceService] Audio tap: FAILED to allocate converted buffer")
                return
            }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error else {
                DebugLog.write("[VoiceService] Audio tap: conversion error: \(error?.localizedDescription ?? "unknown")")
                return
            }

            // Extract float samples as Data
            if let channelData = convertedBuffer.floatChannelData {
                let floatCount = Int(convertedBuffer.frameLength)
                let data = Data(bytes: channelData[0], count: floatCount * MemoryLayout<Float>.size)
                self.appendAudioChunk(data)

                // Stream audio to cloud ASR in real-time
                if let volcEngine = self.asrEngine as? VolcanoASREngine, volcEngine.isStreaming {
                    let samples = Array(UnsafeBufferPointer(start: channelData[0], count: floatCount))
                    let pcm = volcEngine.floatToPCM16(samples)
                    volcEngine.feedAudio(pcm)
                }
            } else {
                DebugLog.write("[VoiceService] Audio tap: no channel data in converted buffer (frameLength=\(convertedBuffer.frameLength))")
            }
        }

        try engine.start()
        self.audioEngine = engine

        // Listen for configuration changes (e.g. WeChat ends a call → device flips
        // back to default sample rate). AVAudioEngine stops itself on this event,
        // so we trigger a rebuild to keep the in-progress recording alive.
        if let existing = audioConfigChangeObserver {
            NotificationCenter.default.removeObserver(existing)
        }
        audioConfigChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.isRecording else { return }
                self.attemptAudioEngineRecovery(reason: "AVAudioEngineConfigurationChange (device format changed mid-recording)")
            }
        }
    }

    /// Tear down the current engine and rebuild it once. Used both as a fast retry
    /// when the first engine failed to deliver any samples (mic was occupied at
    /// startup) and as a recovery from `AVAudioEngineConfigurationChange` (another
    /// app released the device mid-recording, system flipped formats).
    private func attemptAudioEngineRecovery(reason: String) {
        guard isRecording else { return }
        guard !audioRecoveryAttempted else {
            debugLog("Audio engine recovery skipped — already attempted this session (\(reason))")
            return
        }
        audioRecoveryAttempted = true
        debugLog("Audio engine recovery: rebuilding engine — \(reason)")
        stopAudioEngineImmediately()
        do {
            try startAudioEngine()
            debugLog("Audio engine recovery: rebuild succeeded")
        } catch {
            debugLog("Audio engine recovery: rebuild FAILED: \(error) — health check will abort if still no audio")
        }
    }

    /// Default stop path: respects `keepAliveAfterRecording`. For Bluetooth (AirPods)
    /// this keeps the engine running for several seconds so the next press reuses
    /// the warm SCO link without paying another 1–2s warm-up cost. For built-in
    /// mics the keep-alive is shorter but still saves cold-start overhead on rapid
    /// successive recordings. Failure / cancellation paths should call
    /// `stopAudioEngineImmediately()` instead — we don't want to hold the mic open
    /// after an error.
    private func stopAudioEngine() {
        let keepAlive = keepAliveAfterRecording
        guard keepAlive > 0, let engine = audioEngine, engine.isRunning else {
            stopAudioEngineImmediately()
            return
        }

        engineWarmKept = true
        debugLog("Engine kept warm for \(keepAlive)s (next recording will reuse warm link)")
        engineKeepAliveTimer?.invalidate()
        engineKeepAliveTimer = Timer.scheduledTimer(withTimeInterval: keepAlive, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Only actually stop if no recording started in the meantime — a fresh
                // press would have flipped engineWarmKept back to false.
                guard self.engineWarmKept else { return }
                self.debugLog("Engine keep-alive expired, stopping audio engine")
                self.stopAudioEngineImmediately()
            }
        }
    }

    /// Hard stop. Tears down the engine right away — used for errors, cancellation,
    /// and service shutdown.
    private func stopAudioEngineImmediately() {
        engineKeepAliveTimer?.invalidate()
        engineKeepAliveTimer = nil
        engineWarmKept = false
        if let observer = audioConfigChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            audioConfigChangeObserver = nil
        }
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
    }

    // MARK: - Transcription

    /// Process cloud streaming result and inject text.
    private func processAndInject(text: String, chunks: [Data]) async {
        defer { RecordingOverlayPanel.shared.hide() }

        guard !text.isEmpty else {
            state = .ready
            return
        }

        var processedText = TextProcessor.process(
            text: text,
            removeFillers: removeFillers,
            rules: configManager.replacements
        )

        guard !processedText.isEmpty else {
            state = .ready
            return
        }

        state = .ready

        // LLM polish
        let notes = configManager.localLLMNotes
        let polisher: (any TextPolisher)?

        if configManager.llmProviderType == "cloud",
           configManager.cloudLLMEnabled,
           let provider = LLMProvider(rawValue: configManager.llmProvider),
           provider != .none {
            let creds = configManager.llmCredentials[provider.rawValue] ?? ProviderCredentials()
            polisher = LLMClient(provider: provider, credentials: creds, userNotes: notes)
        } else if configManager.llmProviderType == "local", let chatModel, chatModelReady {
            polisher = LocalLLMClient(model: chatModel, userNotes: notes)
        } else {
            polisher = nil
        }

        if let polisher, polisher.shouldPolish(processedText) {
            do {
                let polished = try await polisher.polish(processedText)
                if !polished.isEmpty, polished != processedText {
                    processedText = polished
                }
            } catch {
                // Polish failure shouldn't block injection — the raw (but
                // already filler-removed + replacements-applied) text is still
                // useful. But we surface the error so debugging is possible
                // instead of silently dropping the call.
                debugLog("Polish failed: \(error.localizedDescription)")
                print("[VoiceService] LLM polish failed: \(error)")
            }
        }

        if currentRecordingStreamingPreview {
            RecordingOverlayPanel.shared.updateStreamingText(processedText)
        }

        TextInjector.typeText(processedText, preserveClipboard: configManager.preserveClipboard)
        playEndSound()

        // Self-learning feedback
        if configManager.selfLearningEnabled, processedText.count >= 4 {
            if let windowInfo = FeedbackCollector.captureFrontmostWindowInfo() {
                pendingFeedback = FeedbackCollector.PendingFeedback(
                    injectedText: processedText,
                    windowID: windowInfo.windowID,
                    bundleID: windowInfo.bundleID,
                    timestamp: Date()
                )
                keyboardListener?.feedbackPending = true
                feedbackExpiryTimer?.invalidate()
                feedbackExpiryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.clearPendingFeedback() }
                }
            }
        }

        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let record = TranscriptionRecord(text: processedText, duration: duration)
        if !configManager.privacyMode {
            Task { await historyStore.insert(record) }
        }
    }

    private func transcribeAndInject(chunks: [Data]) async {
        var shouldHideOverlay = true
        defer {
            if shouldHideOverlay { RecordingOverlayPanel.shared.hide() }
        }

        debugLog("transcribeAndInject: chunks=\(chunks.count), totalBytes=\(chunks.reduce(0) { $0 + $1.count })")

        guard !chunks.isEmpty else {
            debugLog("transcribeAndInject SKIPPED: chunks empty — mic delivered no audio")
            shouldHideOverlay = false
            RecordingOverlayPanel.shared.showBriefMessage("麦克风无输入，可能被其他 app 占用")
            state = .ready
            return
        }

        guard let engine = asrEngine else {
            debugLog("transcribeAndInject SKIPPED: asrEngine is nil")
            state = .error("模型未加载")
            return
        }

        let allSamples = mergeAudioSamples(from: chunks)

        guard !allSamples.isEmpty else {
            debugLog("transcribeAndInject SKIPPED: allSamples empty after merge (skipSamples=\(skipSamples))")
            shouldHideOverlay = false
            RecordingOverlayPanel.shared.showBriefMessage("录音过短，没捕获到声音")
            state = .ready
            return
        }

        // Hard floor: below 0.15s we can't realistically transcribe anything —
        // even single Chinese syllables take ~0.2s to articulate. This catches
        // accidental key-touches without rejecting genuine quick utterances.
        // (Was 8000 / 0.5s, which silently rejected words like "好" or "对"
        // when said quickly.)
        guard allSamples.count >= 2400 else {
            debugLog("transcribeAndInject SKIPPED: too short, samples=\(allSamples.count) (need ≥2400)")
            shouldHideOverlay = false
            RecordingOverlayPanel.shared.showBriefMessage("录音过短（不到 0.15 秒）")
            state = .ready
            return
        }

        // Skip transcription if audio is mostly silence/background noise.
        // Distinguish between:
        //   - RMS exactly 0.0 → hardware delivered all-zero buffers (mic likely
        //     held exclusively by another app feeding silence through the shared
        //     CoreAudio device). Point the user at the real cause.
        //   - RMS > 0 but below threshold → genuine quiet / too-far-from-mic.
        let rms = sqrt(allSamples.reduce(0) { $0 + $1 * $1 } / Float(allSamples.count))
        guard rms > 0.003 else {
            debugLog("transcribeAndInject SKIPPED: silent audio, RMS=\(rms) (threshold=0.003), samples=\(allSamples.count)")
            shouldHideOverlay = false
            let msg = rms == 0.0
                ? "麦克风无输入，可能被其他 app 占用"
                : "声音太小，请靠近麦克风"
            RecordingOverlayPanel.shared.showBriefMessage(msg)
            state = .ready
            return
        }
        debugLog("transcribeAndInject: samples=\(allSamples.count), RMS=\(String(format: "%.4f", rms)), duration=\(String(format: "%.1f", Double(allSamples.count) / 16000.0))s")

        // Build hotwords context string
        let hotwords = configManager.hotwords
        let capturedContext = Self.buildHotwordContext(hotwords, appName: recordingAppContext)

        // Run transcription on background thread to keep UI responsive.
        // language: nil = auto-detect (Qwen3-ASR is multilingual; pinning a
        // hint forced Japanese/English speech into Mandarin homophone mode).
        let text = await Task.detached { [engine] in
            let result = engine.transcribe(
                audio: allSamples,
                sampleRate: 16000,
                language: nil,
                context: capturedContext
            )
            // Drop MLX intermediate buffers from the recycle pool. Variable
            // audio lengths produce variable-shape intermediates that the pool
            // cannot reuse, so without this they accumulate indefinitely.
            MLXMemoryGovernor.reclaim()
            return result
        }.value
        debugLog("ASR raw result: \"\(text)\" (empty=\(text.isEmpty)) — \(MLXMemoryGovernor.snapshotDescription())")

        // Process text (Layer 1 filler removal + Layer 2 ITN + replacements)
        var processedText = TextProcessor.process(
            text: text,
            removeFillers: removeFillers,
            rules: configManager.replacements
        )
        debugLog("After TextProcessor: \"\(processedText)\"")

        let isHotwordHallucination = Self.isLikelyHotwordHallucination(processedText, hotwords: hotwords)
        let isSilenceHallucination = Self.isLikelySilenceHallucination(processedText)

        guard !processedText.isEmpty, !isHotwordHallucination, !isSilenceHallucination else {
            debugLog("transcribeAndInject SKIPPED: processedText empty=\(processedText.isEmpty), isHotwordHallucination=\(isHotwordHallucination), isSilenceHallucination=\(isSilenceHallucination)")
            shouldHideOverlay = false
            let msg = isSilenceHallucination
                ? "没识别到有效语音，请检查麦克风"
                : (processedText.isEmpty ? "没识别到内容，请重试" : "识别异常，请重试")
            RecordingOverlayPanel.shared.showBriefMessage(msg)
            state = .ready
            return
        }

        // Restore state so user can start a new recording immediately.
        state = .ready

        // Layer 3: LLM polish
        let notes = configManager.localLLMNotes
        let polisher: (any TextPolisher)?

        if configManager.llmProviderType == "cloud",
           configManager.cloudLLMEnabled,
           let provider = LLMProvider(rawValue: configManager.llmProvider),
           provider != .none {
            let creds = configManager.llmCredentials[provider.rawValue] ?? ProviderCredentials()
            NSLog("[VoiceService] LLM polish (cloud/%@): input=\"%@\", notes=\"%@\"", provider.rawValue, processedText, notes)
            polisher = LLMClient(provider: provider, credentials: creds, userNotes: notes)
        } else if configManager.llmProviderType == "local", let chatModel, chatModelReady {
            NSLog("[VoiceService] LLM polish (local): input=\"%@\", notes=\"%@\"", processedText, notes)
            polisher = LocalLLMClient(model: chatModel, userNotes: notes)
        } else {
            polisher = nil
            NSLog("[VoiceService] LLM polish: skipped (not configured or model not ready)")
        }

        if let polisher, polisher.shouldPolish(processedText) {
            do {
                let polished = try await polisher.polish(processedText)
                if !polished.isEmpty, polished != processedText {
                    NSLog("[VoiceService] LLM polish: output=\"%@\"", polished)
                    processedText = polished
                } else {
                    NSLog("[VoiceService] LLM polish: no change")
                }
            } catch {
                NSLog("[VoiceService] LLM polish failed: %@", String(describing: error))
            }
        }

        // Update panel with final text before injection
        if currentRecordingStreamingPreview {
            RecordingOverlayPanel.shared.updateStreamingText(processedText)
        }

        // Inject text
        TextInjector.typeText(processedText, preserveClipboard: configManager.preserveClipboard)
        playEndSound()

        // Set up self-learning feedback if enabled (async to avoid blocking)
        debugLog("selfLearningEnabled=\(configManager.selfLearningEnabled), textLen=\(processedText.count)")
        if configManager.selfLearningEnabled, processedText.count >= 4 {
            Task { @MainActor in
                if let windowInfo = FeedbackCollector.captureFrontmostWindowInfo() {
                    debugLog("Feedback setup: windowID=\(windowInfo.windowID), bundleID=\(windowInfo.bundleID)")
                    pendingFeedback = FeedbackCollector.PendingFeedback(
                        injectedText: processedText,
                        windowID: windowInfo.windowID,
                        bundleID: windowInfo.bundleID,
                        timestamp: Date()
                    )
                    keyboardListener?.feedbackPending = true

                    // Expire after 30 seconds
                    feedbackExpiryTimer?.invalidate()
                    feedbackExpiryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                        Task { @MainActor in
                            self?.clearPendingFeedback()
                        }
                    }
                }
            }
        }

        // Record to history
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let record = TranscriptionRecord(text: processedText, duration: duration)
        if !configManager.privacyMode {
            Task { await historyStore.insert(record) }
        }
    }

    // MARK: - Self-Learning Feedback

    private func handleEnterPress() {
        debugLog("handleEnterPress called, pendingFeedback=\(pendingFeedback == nil ? "nil" : "exists")")
        guard let pending = pendingFeedback else { return }
        guard Date().timeIntervalSince(pending.timestamp) < 30 else {
            debugLog("Feedback expired (\(Date().timeIntervalSince(pending.timestamp))s)")
            clearPendingFeedback()
            return
        }

        let capturedPending = pending
        clearPendingFeedback()

        Task {
            let actualText = await FeedbackCollector.collectText(for: capturedPending)
            debugLog("OCR result: \(actualText ?? "nil")")
            guard let actualText else { return }
            debugLog("Injected: \(capturedPending.injectedText) | Actual: \(actualText)")
            await CorrectionAnalyzer.processCorrection(
                injected: capturedPending.injectedText,
                actual: actualText,
                bundleID: capturedPending.bundleID,
                correctionStore: correctionStore,
                configManager: configManager
            )
        }
    }

    private func clearPendingFeedback() {
        pendingFeedback = nil
        keyboardListener?.feedbackPending = false
        feedbackExpiryTimer?.invalidate()
        feedbackExpiryTimer = nil
    }

    // MARK: - Hotword Context

    /// Wrap hotwords in a Chinese descriptive phrase so the model treats them as
    /// reference vocabulary rather than priming itself to echo them as the
    /// transcription. Passing a raw space-joined word list (the previous behavior)
    /// causes the model to regurgitate hotwords verbatim on short/silent audio.
    static func buildHotwordContext(_ hotwords: [String], appName: String? = nil) -> String? {
        let cleaned = hotwords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var parts: [String] = []
        if let appName, !appName.isEmpty {
            parts.append("用户正在使用 \(appName)")
        }
        if !cleaned.isEmpty {
            parts.append("可能出现以下专有名词：" + cleaned.joined(separator: "、"))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "。") + "。"
    }

    /// Captures the frontmost non-VoiceBubble app's localized name. Returns nil in
    /// privacy mode or when the frontmost app is our own process (panel focus edge case).
    static func captureFrontmostAppName(privacyMode: Bool) -> String? {
        guard !privacyMode else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        // Skip our own bundle — panel can briefly be frontmost in edge cases.
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }
        guard let name = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        // Defensive cap: don't let a weirdly long app name bloat the ASR prompt.
        return name.count > 40 ? String(name.prefix(40)) : name
    }

    /// Phrases that only appear inside our hotword priming prompt. If the ASR
    /// output contains any of these, the model is echoing the context verbatim
    /// — the user definitely did not speak this. Catches the failure mode
    /// where the user holds the trigger key but stays silent: the model
    /// regurgitates the whole "音频中可能出现以下专有名词：…" prompt.
    private static let hotwordPromptMarkers: [String] = [
        "音频中可能出现以下专有名词",
        "音频中可能出现",
        "以下专有名词",
        "可能出现以下专有名词",
        "用户正在使用"
    ]

    /// Detect when the ASR output is dominated by hotword content — a sign the
    /// model hallucinated from in-context priming. Catches:
    ///   1. Output containing the literal priming prompt prefix.
    ///   2. Output that is *only* hotwords + punctuation.
    ///   3. Output that is almost entirely hotwords with a few stray characters.
    static func isLikelyHotwordHallucination(_ text: String, hotwords: [String]) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !hotwords.isEmpty else { return false }

        // (1) Definitive: the output echoes our prompt prefix. No real speaker
        // says "音频中可能出现以下专有名词" out loud — that's our scaffolding text.
        for marker in hotwordPromptMarkers where trimmed.contains(marker) {
            return true
        }

        var hotwordTokens = Set<String>()
        for word in hotwords {
            let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !w.isEmpty else { continue }
            hotwordTokens.insert(w)
            for token in w.split(separator: " ").map(String.init) where !token.isEmpty {
                hotwordTokens.insert(token)
            }
        }

        var remaining = trimmed
        for token in hotwordTokens.sorted(by: { $0.count > $1.count }) {
            remaining = remaining.replacingOccurrences(of: token, with: "")
        }
        remaining = remaining.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

        // Strict: nothing but hotwords + punctuation.
        if remaining.isEmpty { return true }

        // Loose: hotwords account for ≥80% of the output AND ≤18 stray bytes left.
        // Use UTF-8 byte count so the threshold treats Chinese (~3 bytes/char) and
        // English (~1 byte/char) on equal footing — counting characters would unfairly
        // flag short Chinese phrases as hallucinations while letting long English
        // ones through.
        let trimmedBytes = trimmed.utf8.count
        let remainingBytes = remaining.utf8.count
        guard trimmedBytes > 0 else { return false }
        let strippedRatio = 1.0 - Double(remainingBytes) / Double(trimmedBytes)
        if strippedRatio >= 0.8 && remainingBytes <= 18 { return true }

        return false
    }

    /// Phrases Qwen3-ASR tends to output when the audio is too quiet, too short,
    /// or the mic captured background noise only. These are verbatim model
    /// fallbacks, never things the user actually said — treat them as failures
    /// and tell the user the mic didn't pick up their voice.
    private static let silenceHallucinationPhrases: Set<String> = [
        "没有任何声音", "没有任何声音。",
        "没有声音", "没有声音。",
        "没声音", "没声音。",
        "无声", "无声。",
        "听不清", "听不清。",
        "听不见", "听不见。",
        "没有说话", "没有说话。",
        "没人说话", "没人说话。",
        "没有人说话", "没有人说话。",
        "（无声）", "(无声)",
        "（静音）", "(静音)"
    ]

    static func isLikelySilenceHallucination(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return silenceHallucinationPhrases.contains(trimmed)
    }

    // MARK: - Input Device Selection

    /// Returns `true` if the current system default input device is a Bluetooth mic
    /// (AirPods, generic BT headset, etc.). When true, downstream timing parameters
    /// — prewarm length, health-check window, leading-silence skip — get widened to
    /// accommodate the slow A2DP→HFP/SCO switch.
    ///
    /// The transport type is read fresh each call (not cached) because the user can
    /// connect/disconnect AirPods mid-session and we want to react.
    static func isCurrentInputBluetooth() -> Bool {
        guard let transport = currentDefaultInputTransportType() else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Look up the system default input device and return its CoreAudio transport type.
    /// Returns nil if no default input is set (rare — usually only on freshly booted
    /// machines with no mic at all).
    private static func currentDefaultInputTransportType() -> UInt32? {
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddr, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }

        var transportAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &transportAddr, 0, nil, &transportSize, &transport
        ) == noErr else { return nil }
        return transport
    }

    /// Find the MacBook's built-in microphone and bind `engine`'s inputNode to it.
    /// Falls back silently if the built-in mic can't be located (e.g. headless Mac mini),
    /// in which case AVAudioEngine uses the system default — better than crashing.
    ///
    /// Why this exists: on macOS, when AirPods/any Bluetooth mic is the system
    /// default, AVAudioEngine's input path grabs it and switches the headset
    /// into HFP/SCO mode (16 kHz mono, phone-call audio). That link is unstable
    /// and frequently delivers all-zero buffers — which is what we observed in
    /// production logs (`tapFired=47, RMS=0.0`). Forcing built-in bypasses the
    /// problem entirely and keeps A2DP intact for music playback in headphones.
    ///
    /// NOTE: Currently unused — we now respect the user's chosen input device
    /// (including AirPods) and absorb the SCO-link cost via Bluetooth-aware
    /// timing. Kept around in case we want a "force built-in" toggle later.
    private static func forceInputToBuiltInMic(engine: AVAudioEngine, debug: ((String) -> Void)?) {
        guard let deviceID = findBuiltInInputDeviceID() else {
            debug?("forceInputToBuiltInMic: no built-in input device found, using system default")
            return
        }
        guard let audioUnit = engine.inputNode.audioUnit else {
            debug?("forceInputToBuiltInMic: inputNode.audioUnit is nil")
            return
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr {
            debug?("forceInputToBuiltInMic: bound to deviceID=\(deviceID)")
        } else {
            debug?("forceInputToBuiltInMic: AudioUnitSetProperty failed, status=\(status)")
        }
    }

    /// Enumerate CoreAudio devices and return the first one that has input
    /// streams and reports `kAudioDeviceTransportTypeBuiltIn`. On Apple Silicon
    /// Macs with only a built-in mic this is trivially the right answer; on
    /// Intel with multiple built-ins (rare) we take the first match.
    private static func findBuiltInInputDeviceID() -> AudioDeviceID? {
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size
        ) == noErr, size > 0 else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size, &devices
        ) == noErr else { return nil }

        for deviceID in devices {
            // Must expose input streams — rules out output-only devices.
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &streamAddr, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { continue }

            // Must be transport type "built-in".
            var transportAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(
                deviceID, &transportAddr, 0, nil, &transportSize, &transport
            ) == noErr else { continue }

            if transport == kAudioDeviceTransportTypeBuiltIn {
                return deviceID
            }
        }
        return nil
    }

    // MARK: - Debug

    private func debugLog(_ message: String) {
        DebugLog.write("[VoiceService] \(message)")
    }

    // MARK: - Download Progress

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

    // MARK: - Polish Model Management

    /// Manually start the local polish model (download + load).
    func startChatModel() {
        guard !chatModelReady, !chatModelLoading else { return }
        chatModelLoading = true
        chatModelDownloadProgress = nil
        Task { @MainActor in
            do {
                let currentModel = PolishModel(rawValue: configManager.polishModel) ?? .qwen3Chat
                let modelId = currentModel.huggingFaceId
                let approxTotal: Int64 = 318_000_000
                print("[VoiceService] Loading polish model: \(modelId)")
                let model = try await Qwen3ChatModel.fromPretrained(
                    modelId: modelId,
                    progressHandler: { [weak self] progress, status in
                        Task { @MainActor in
                            let downloaded = Int64(progress * Double(approxTotal))
                            self?.chatModelDownloadProgress = DownloadProgress(
                                downloaded: downloaded,
                                total: approxTotal,
                                description: status
                            )
                        }
                    }
                )
                self.chatModel = model
                self.chatModelReady = true
                self.chatModelLoading = false
                self.chatModelDownloadProgress = nil
                print("[VoiceService] Polish model ready")
            } catch {
                print("[VoiceService] Polish model load failed: \(error)")
                self.chatModelLoading = false
                self.chatModelDownloadProgress = nil
            }
        }
    }

    /// Manually stop and unload the local polish model.
    func stopChatModel() {
        if let model = chatModel {
            model.unload()
            chatModel = nil
        }
        chatModelReady = false
        chatModelLoading = false
        chatModelDownloadProgress = nil
    }

    // MARK: - Helpers

    /// Update keyboard listener when trigger key changes. Call after restart.
    func updateTriggerKey() {
        keyboardListener?.stop()
        if state == .ready {
            startKeyboardListener()
        }
    }

    /// Expose the keyboard listener for MeetingService to set meetingActive.
    var keyboardListenerRef: KeyboardListener? {
        keyboardListener
    }

    /// Expose the ASR engine for MeetingService to borrow.
    var asrEngineRef: (any ASREngineProtocol)? {
        asrEngine
    }
}
