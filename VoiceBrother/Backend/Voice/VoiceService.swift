import AVFoundation
import AppKit
import AudioCommon
import AudioToolbox
import Combine
import CoreAudio
import CoreGraphics
import Foundation
import Qwen3ASR
import Speech

/// Connection-warm-up state for the cloud text-polish LLM. Flipping the
/// `cloudLLMEnabled` switch fires a ping so the TLS connection is pooled
/// before the first real polish call; the settings card and the menu-bar
/// LLM row both render this instead of a bare "已启用".
enum LLMWarmupState: Equatable {
    case idle, connecting, ready
    case failed(String)
}

/// Main voice input lifecycle service.
/// Manages ASR model loading, audio recording, transcription, and text injection.
@MainActor
final class VoiceService: ObservableObject, VoiceServiceProtocol {

    // MARK: - Published State

    @Published var state: ServiceState = .stopped
    @Published var downloadProgress: DownloadProgress?
    @Published var spaceReposition: Bool
    /// Live cloud-LLM connection-warm-up state. Driven by `cloudLLMEnabled`
    /// flipping on/off (see the subscription in `init`); read by the settings
    /// card and the menu-bar LLM row.
    @Published var llmWarmupState: LLMWarmupState = .idle

    // MARK: - Dependencies

    private let configManager: ConfigManager
    private let historyStore = HistoryStore()
    private var llmWarmupCancellable: AnyCancellable?

    /// Callback to toggle meeting recording, set by the app after MeetingService is created.
    var meetingToggleAction: (() -> Void)?

    // MARK: - Internal State

    private(set) var asrEngine: (any ASREngineProtocol)?
    /// Human-readable label of the ASR model behind the live engine, copied
    /// into every history record for diagnostics. Set when an engine starts.
    private(set) var loadedModelLabel: String = ""

    /// In-flight Qwen transcribe task — kept so we can abandon it if MLX wedges
    /// on the first inference after a long idle (the GPU command buffer can
    /// stall when 2+ GB of weights are paged back in). Cancelling the wrapper
    /// won't actually interrupt the synchronous MLX call, but it lets the UI
    /// stop waiting on it and avoids stale results overwriting fresh state
    /// when the user reloads the model to recover.
    private var currentTranscribeTask: Task<String, Never>?
    /// Hard ceiling on a single transcribe call before we surface "timeout"
    /// to the user. Normal latency is well under 1 s even on the 1.7B model;
    /// 15 s gives a generous margin for legitimate post-idle slow paths.
    private static let transcribeTimeoutSeconds: UInt64 = 15
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

    /// Tail-capture window, in milliseconds. Aggressive setting: trades the
    /// last ~50–100 ms of trailing audio for snappier text appearance. Most
    /// casual releases happen after the final syllable is articulated, so the
    /// shortened window rarely clips. Increase to 200–250 if trailing words
    /// start getting cut.
    private static let tailCaptureMillis: UInt64 = 150

    /// Diagnostic: count of audio tap callbacks received during current recording.
    /// Incremented from the CoreAudio IO thread (tap callback) and read/reset
    /// from the main actor (health-check timer), so all access goes through a
    /// lock — without it the `+= 1` read-modify-write races the main-actor reset
    /// and the "mic occupied" health check can observe a torn/stale value.
    private let tapFireCountLock = NSLock()
    private var _tapFireCount: Int = 0
    private var tapFireCount: Int {
        get { tapFireCountLock.withLock { _tapFireCount } }
        set { tapFireCountLock.withLock { _tapFireCount = newValue } }
    }
    /// Atomic increment for the tap callback — the computed-property setter would
    /// take the lock twice (get then set), reopening the race.
    private func incrementTapFireCount() {
        tapFireCountLock.withLock { _tapFireCount += 1 }
    }

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

    /// UUID identifying the current voice session, used as the `session` field
    /// in `ASRLogger` events so a `tail -f /tmp/vb_asr_events.log` can be
    /// filtered to one press. Refreshed in `handleKeyPress`; never cleared so
    /// late events (e.g. inject_completed after a quick second press) still
    /// carry the press they belong to.
    private var currentSessionID: UUID?

    /// Safety timer to auto-stop recording after 120 seconds.
    private var safetyTimer: Timer?

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

    /// True while a cold engine start is in flight. `startAudioEngine()` now
    /// awaits its CoreAudio HAL calls off the main thread (so a wedged
    /// coreaudiod can't freeze the UI), which means it can suspend. This flag
    /// serializes the cold-start path: a second key press / focus warm-up while
    /// one start is still in flight is rejected rather than racing a second
    /// `AVAudioEngine` onto the same microphone. Only touched on the main actor.
    private var isStartingEngine = false

    /// Observer for `AVAudioEngineConfigurationChange`. Fires when the underlying
    /// audio device's config changes — typically when another app (WeChat, Zoom,
    /// etc.) ends a call and the system flips the input device back to its default
    /// sample rate. AVAudioEngine stops itself when this happens; we rebuild so
    /// the user's in-progress recording survives the transition.
    private var audioConfigChangeObserver: NSObjectProtocol?

    /// Tracks in-flight transcription/finalize work so we can await completion
    /// before yielding the shared ASR engine to the meeting service. The engine
    /// is not thread-safe; running voice and meeting transcribe concurrently
    /// on the same model will corrupt results or crash.
    private var pendingASRTask: Task<Void, Never>?

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
        // Bluetooth bumped from 8s → 300s (5 min) to mirror how Doubao input method
        // feels: once the SCO link is up, every press for the next 5 minutes is
        // instant. Trade-off is AirPods music quality stays degraded (mono HFP) and
        // a slight battery cost while warm. Same approach used by macos-mic-keepwarm
        // and other push-to-talk tools. Built-in mic keep-alive stays at 3s — built-in
        // has no SCO cost so a long window has no benefit.
        Self.isCurrentInputBluetooth() ? 300.0 : 3.0
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

    /// Polls system-wide focused element to detect when the user is in a text-
    /// editable context. While true, we proactively bring the audio engine up so
    /// the Bluetooth SCO link is already warm when the user presses the trigger.
    /// Mirrors how IME-class apps (e.g. Doubao input method) avoid cold-start lag.
    private var focusObserver: FocusObserver?

    /// True while the user's keyboard focus is on a text-editable element AND we've
    /// reflected that into keeping the engine alive. Used so a recording that ends
    /// while focus is still on an editable field doesn't drop the engine on its
    /// keep-alive timer — we hold it through the focus instead.
    private var isFocusWarmEngaged = false

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
        self.spaceReposition = configManager.spaceReposition

        // Warm the polish-LLM connection the moment either consumer turns on —
        // voice input (`cloudLLMEnabled`) or meeting summary (`meetingLLMEnabled`).
        // Both share one provider/endpoint, so one pooled TLS connection and one
        // warm-up state cover both. Fires at launch too, since `@Published`
        // replays current values to a new subscriber. The first call then never
        // pays the cold DNS/TLS handshake.
        llmWarmupCancellable = configManager.appConfig.$cloudLLMEnabled
            .combineLatest(configManager.appConfig.$meetingLLMEnabled)
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { [weak self] anyEnabled in
                Task { @MainActor in
                    guard let self else { return }
                    if anyEnabled { self.warmUpLLM() } else { self.llmWarmupState = .idle }
                }
            }
    }

    /// Either LLM consumer (voice polish or meeting summary) wants the cloud
    /// connection alive — they share one provider/endpoint, so one warm-up
    /// state serves both.
    private var anyLLMEnabled: Bool {
        configManager.cloudLLMEnabled || configManager.meetingLLMEnabled
    }

    // MARK: - LLM Connection Warm-up

    /// Fire a tiny ping so the TLS connection to the polish LLM is opened and
    /// pooled in `URLSession.shared` before the first real polish call.
    func warmUpLLM() {
        guard anyLLMEnabled else { return }
        guard let provider = LLMProvider(rawValue: configManager.llmProvider),
              provider != .none else {
            llmWarmupState = .failed("未配置提供商")
            return
        }
        let creds = configManager.llmCredentials[provider.rawValue] ?? ProviderCredentials()
        if provider.requiresAPIKey,
           creds.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            llmWarmupState = .failed("未配置 API Key")
            return
        }
        llmWarmupState = .connecting
        Task {
            let client = LLMClient(provider: provider, credentials: creds,
                                   userNotes: "", timeout: 20, maxTokens: 16)
            do {
                _ = try await client.call(
                    systemPrompt: "连接预热，收到后只回复 ok。",
                    userMessage: "ping")
                // Both switches may have flipped off mid-ping — don't resurrect
                // a stale state on the UI.
                if anyLLMEnabled { llmWarmupState = .ready }
            } catch {
                if anyLLMEnabled {
                    llmWarmupState = .failed(Self.shortWarmupError(error))
                }
            }
        }
    }

    private static func shortWarmupError(_ error: Error) -> String {
        let raw = (error as? LLMError)?.errorDescription ?? error.localizedDescription
        return raw.count > 40 ? String(raw.prefix(40)) + "…" : raw
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
        // framework will silently return empty strings if the selected on-device asset is
        // missing — we'd rather tell the user exactly where to go than leave them puzzled
        // by transcripts that always come back blank. Check the *selected* input language,
        // not a hard-coded zh-Hans, so English/Japanese users aren't blocked by a missing
        // Chinese asset they never use.
        let inputLanguage = configManager.voiceInputLanguage
        if !engine.isLanguageReady(inputLanguage.asrLanguageHint) {
            state = .error("\(inputLanguage.displayName)语音模型未就绪，请在「系统设置 → 键盘 → 听写」中添加\(inputLanguage.displayName)后重试")
            return
        }

        self.asrEngine = engine
        loadedModelLabel = ASRModel.apple.fullName
        state = .ready
        startKeyboardListener()
        prewarmAudioEngine()
    }

    private func startQwenASR(model: ASRModel) async throws {
        let hfId = model.huggingFaceId

        // If a previous transcribe is still in flight (e.g. MLX wedged on the
        // first inference after long idle and the user is reloading to recover),
        // abandon it so its stale result can't overwrite the fresh UI state
        // and the panel returns to a clean baseline immediately.
        if currentTranscribeTask != nil {
            debugLog("startQwenASR: abandoning in-flight transcribe task before reload")
            currentTranscribeTask?.cancel()
            currentTranscribeTask = nil
            RecordingOverlayPanel.shared.hide()
        }

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
        loadedModelLabel = model.fullName
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
        case .openaiWhisper:
            guard !creds.apiKey.isEmpty else {
                state = .error("请配置 OpenAI API Key")
                return
            }
            self.asrEngine = OpenAIWhisperASREngine(
                apiKey: creds.apiKey,
                baseURL: creds.baseURL.isEmpty ? provider.defaultBaseURL : creds.baseURL,
                model: creds.model.isEmpty ? provider.defaultModel : creds.model
            )

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

        case .deepgram:
            state = .error("\(provider.displayName) 暂未实现")
            return
        }

        loadedModelLabel = "云端·" + provider.displayName
        state = .ready
        startKeyboardListener()
        prewarmAudioEngine()
    }

    func stop() {
        // Cancel safety timer
        safetyTimer?.invalidate()
        safetyTimer = nil

        // Cancel audio health check timer
        audioHealthCheckTimer?.invalidate()
        audioHealthCheckTimer = nil
        audioRecoveryTimer?.invalidate()
        audioRecoveryTimer = nil

        // Stop keyboard listener
        keyboardListener?.stop()
        keyboardListener = nil

        // Stop focus observer. Flag is forced false so its disengage path doesn't
        // schedule a keep-alive timer right before we tear the engine down hard.
        focusObserver?.stop()
        focusObserver = nil
        isFocusWarmEngaged = false

        // Stop audio engine — service teardown is a hard stop, no keep-alive
        stopAudioEngineImmediately()

        // Unload ASR engine
        asrEngine?.unload()
        asrEngine = nil

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
            }
        )

        listener.start()
        self.keyboardListener = listener

        startFocusObserver()
    }

    /// Spin up the focus poller. Only useful when the input is Bluetooth — for
    /// built-in mics the engine can cold-start in <100ms so pre-warming is wasted
    /// work. We still attach the observer unconditionally so a mid-session switch
    /// to AirPods immediately benefits; the engage/disengage paths check the
    /// transport type at the moment of action.
    private func startFocusObserver() {
        focusObserver?.stop()
        let observer = FocusObserver()
        observer.onEditableFocused = { [weak self] in
            Task { @MainActor in await self?.engageFocusWarmUp() }
        }
        observer.onEditableUnfocused = { [weak self] in
            Task { @MainActor in self?.disengageFocusWarmUp() }
        }
        observer.start()
        self.focusObserver = observer
    }

    /// Bring the audio engine up because the user is on a text-editable field.
    /// Idempotent — calling while already engaged just refreshes the keep-alive.
    /// No-op on built-in mic (no SCO cost to pay) or when the service isn't ready.
    private func engageFocusWarmUp() async {
        guard Self.isCurrentInputBluetooth() else { return }
        guard keyboardListenerRef?.isMeetingActive != true else { return }
        guard state == .ready else { return }

        // Recording is in progress: the engine is already up under recording's
        // control. Remember the focus state so the post-recording finalize can
        // hold the engine instead of letting keep-alive expire on it.
        if isRecording {
            isFocusWarmEngaged = true
            return
        }

        isFocusWarmEngaged = true

        // Engine already up (post-recording keep-alive, or a prior focus warm).
        // Just cancel any pending shutdown so we don't drop it under our feet.
        if let engine = audioEngine, engine.isRunning {
            engineKeepAliveTimer?.invalidate()
            engineKeepAliveTimer = nil
            engineWarmKept = true
            debugLog("Focus warm-up: holding already-running engine (text field focused)")
            return
        }

        // Don't race a focus warm-up cold start against an in-flight engine
        // start (a key press starting a real recording). Whoever got there
        // first wins; this one bows out.
        guard !isStartingEngine else {
            debugLog("Focus warm-up: skipped — an engine start is already in flight")
            isFocusWarmEngaged = false
            return
        }
        isStartingEngine = true
        defer { isStartingEngine = false }
        do {
            try await startAudioEngine()
            // A meeting may have grabbed the mic, or focus may have moved away,
            // during the cold-start await — don't leave a resurrected engine.
            guard isFocusWarmEngaged, keyboardListenerRef?.isMeetingActive != true else {
                debugLog("Focus warm-up: state changed during cold start — releasing engine")
                stopAudioEngineImmediately()
                isFocusWarmEngaged = false
                return
            }
            debugLog("Focus warm-up: cold-started audio engine (text field focused)")
        } catch {
            debugWarn("Focus warm-up: cold start FAILED: \(error)")
            isFocusWarmEngaged = false
        }
    }

    /// Release the warm-up hold. If a recording is in progress, just clears the
    /// flag — recording controls the engine. Otherwise, hand the engine over to
    /// the keep-alive timer so it expires on the same generous schedule recording
    /// teardown uses (5 min on Bluetooth).
    private func disengageFocusWarmUp() {
        guard isFocusWarmEngaged else { return }
        isFocusWarmEngaged = false
        guard !isRecording else { return }
        guard let engine = audioEngine, engine.isRunning else { return }
        guard engineKeepAliveTimer == nil else { return }
        debugLog("Focus warm-up: releasing — keep-alive timer will hold engine for \(keepAliveAfterRecording)s")
        stopAudioEngine()
    }

    // MARK: - Key Event Handlers

    /// Whether cloud streaming is active for the current recording.
    private var isCloudStreaming: Bool {
        (asrEngine as? VolcanoASREngine)?.isStreaming == true
    }

    private func handleKeyPress() {
        guard state == .ready, !isRecording, !isStartingEngine else {
            debugLog("handleKeyPress REJECTED: state=\(state.displayText), isRecording=\(isRecording), isStartingEngine=\(isStartingEngine)")
            ASRLogger.shared.event(.keyPress, sessionID: currentSessionID,
                                   props: ["rejected": true, "state": state.displayText])
            return
        }

        let session = UUID()
        currentSessionID = session
        ASRLogger.shared.event(.sessionBegin, sessionID: session,
                               props: ["bluetooth": Self.isCurrentInputBluetooth()])

        isRecording = true
        clearAudioChunks()
        tapFireCount = 0
        hasReceivedRealAudio = false  // gate that skips Bluetooth SCO warm-up zeros
        streamingPeak = 0
        audioRecoveryAttempted = false
        isStartingEngine = true

        // `startAudioEngine()` awaits its CoreAudio HAL calls off the main
        // thread (see that function). The rest of the start sequence — frontmost
        // app, overlay, sound, timers — still runs only once the engine is
        // actually up, in exactly the same order as before; the only difference
        // is the UI no longer freezes while a slow coreaudiod settles.
        Task { @MainActor in
            defer { isStartingEngine = false }
            do {
                // Start the audio engine FIRST. On Bluetooth the SCO link can
                // take 0.5–1.5s to come up, so every millisecond before this
                // call is leading speech we don't lose.
                try await startAudioEngine()

                // The user may have released the key, hit ESC, or started a
                // meeting during the cold-start await. If this session is no
                // longer the active one, tear the just-built engine down rather
                // than resurrecting a recording that was already finalized.
                guard currentSessionID == session, isRecording, !isCapturingTail else {
                    debugLog("handleKeyPress: session no longer active after engine start — discarding engine")
                    stopAudioEngineImmediately()
                    return
                }

                recordingAppContext = Self.captureFrontmostAppName()
                recordingStartTime = Date()
                state = .recording
                debugLog("Recording started successfully, appContext=\(recordingAppContext ?? "nil")")
                ASRLogger.shared.event(.recordingStarted, sessionID: session,
                                       props: ["app": recordingAppContext ?? ""])

                // Start cloud streaming if using VolcanoASREngine
                if let volcEngine = asrEngine as? VolcanoASREngine {
                    volcEngine.beginStreaming(sampleRate: 16000, language: "Chinese")
                    // 渐进上屏不再在浮窗显示识别预览(只保留波形),所以不消费 partial。
                    volcEngine.onStreamingUpdate = nil
                }

                RecordingOverlayPanel.shared.show()
                ASRLogger.shared.event(.panelPresentRecording, sessionID: session)
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
                        self.debugError("Audio health check FAILED: tapFireCount=0 after \(healthTimeout)s — aborting, mic likely occupied")
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
                        await self.attemptAudioEngineRecovery(reason: "no audio after \(recoveryDelay)s")
                    }
                }

            } catch {
                debugError("FAILED to start audio engine: \(error)")
                print("[VoiceService] Failed to start audio engine: \(error)")
                ASRLogger.shared.event(.asrFailed, sessionID: session,
                                       props: ["stage": "audio_engine_start",
                                               "error": "\(error)"])
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
                state = .ready
            }
        }
    }

    /// Tear down an in-progress recording and surface a message to the user.
    /// Shared exit path for silent-failure cases (mic occupied, no audio
    /// captured, etc.) — keeps state cleanup in one place so future exits
    /// can't forget to invalidate a timer or leave a stale flag. Uses the
    /// immediate stop path: when something went wrong we don't want to keep
    /// holding the mic open for a "warm" follow-up.
    private func abortRecordingWithMessage(_ message: String) {
        ASRLogger.shared.event(.interruptMicOccupied, sessionID: currentSessionID,
                               props: ["msg": message])
        isRecording = false
        safetyTimer?.invalidate(); safetyTimer = nil
        audioHealthCheckTimer?.invalidate(); audioHealthCheckTimer = nil
        audioRecoveryTimer?.invalidate(); audioRecoveryTimer = nil
        stopAudioEngineImmediately()
        clearAudioChunks()
        (asrEngine as? VolcanoASREngine)?.cancelStreaming()
        RecordingOverlayPanel.shared.showBriefMessage(message)
        ASRLogger.shared.event(.panelHidden, sessionID: currentSessionID,
                               props: ["reason": "abort"])
        state = .ready
    }

    private func handleKeyRelease() {
        guard isRecording else {
            debugLog("handleKeyRelease REJECTED: isRecording=false (recording never started?)")
            ASRLogger.shared.event(.keyRelease, sessionID: currentSessionID,
                                   props: ["rejected": true])
            return
        }
        let recDuration = recordingStartTime.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        ASRLogger.shared.event(.keyRelease, sessionID: currentSessionID,
                               props: ["rec_ms": recDuration, "taps": tapFireCount,
                                       "typewriter": configManager.typewriterMode])

        // Hide the overlay the instant the user lets go — the bubble's job
        // is to confirm "I'm listening", not "I'm thinking". ASR + tail
        // capture run in the background; if transcription fails, the bubble
        // will flash back via showBriefMessage. The mic stays open for a
        // short tail-capture window so trailing syllables aren't clipped.
        //
        // 渐进上屏例外:本模式下浮窗(只显示波形)保留到 inject 结束才隐藏,
        // 由 injectFinalText 键入完成后调 hide()。
        if !configManager.typewriterMode {
            RecordingOverlayPanel.shared.hide()
            ASRLogger.shared.event(.panelHidden, sessionID: currentSessionID,
                                   props: ["reason": "key_release"])
        }
        isCapturingTail = true

        // Stop the timers immediately — no point doing health checks
        // during the tail.
        safetyTimer?.invalidate()
        safetyTimer = nil
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
        guard isCapturingTail else {
            ASRLogger.shared.event(.dropLateResult, sessionID: currentSessionID,
                                   props: ["stage": "finalize", "reason": "isCapturingTail=false"])
            return
        }
        ASRLogger.shared.event(.stopRequested, sessionID: currentSessionID)
        isCapturingTail = false
        isRecording = false

        let chunks = swapAudioChunks()
        let engineRunning = audioEngine?.isRunning ?? false
        stopAudioEngine()
        // If focus is still on a text-editable field, hold the engine open instead
        // of letting the keep-alive expire. The keep-alive timer is the right
        // baseline when the user finishes recording and moves on, but here the
        // FocusObserver tells us they're still in a "ready to dictate" context.
        if isFocusWarmEngaged {
            engineKeepAliveTimer?.invalidate()
            engineKeepAliveTimer = nil
            engineWarmKept = true
            debugLog("finalizeRecordingAfterTail: holding engine — text field still focused")
        }
        let recordDuration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        debugLog("finalizeRecordingAfterTail: chunks=\(chunks.count), totalBytes=\(chunks.reduce(0) { $0 + $1.count }), duration=\(String(format: "%.1f", recordDuration))s, tapFired=\(tapFireCount), engineRunning=\(engineRunning)")

        state = .transcribing

        // Cloud streaming: finish and get result immediately (audio already sent)
        if let volcEngine = asrEngine as? VolcanoASREngine, volcEngine.isStreaming {
            pendingASRTask = Task { @MainActor in
                let text = await Task.detached { volcEngine.finishStreaming() }.value
                await self.processAndInject(text: text, chunks: chunks)
            }
        } else {
            pendingASRTask = Task { @MainActor in
                await transcribeAndInject(chunks: chunks)
            }
        }
    }

    private func handleCancel() {
        guard isRecording || state == .recording else { return }
        ASRLogger.shared.event(.interruptEsc, sessionID: currentSessionID)
        // Abort any pending tail-capture so the scheduled finalize bails out.
        isCapturingTail = false
        isRecording = false
        safetyTimer?.invalidate()
        safetyTimer = nil
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
        ASRLogger.shared.event(.panelHidden, sessionID: currentSessionID,
                               props: ["reason": "esc"])
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
        ASRLogger.shared.event(.interruptMeetingToggle, sessionID: currentSessionID,
                               props: ["wasRecording": isRecording])
        // Cancel any in-progress voice recording (including tail capture)
        if isRecording {
            isCapturingTail = false
            isRecording = false
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
            meetingToggleAction?()
        }
    }

    // MARK: - Audio Engine

    /// Pre-warm audio hardware by briefly starting and stopping the engine.
    /// This ensures the first real recording has full audio levels instead of
    /// near-zero samples. Bluetooth gets a longer warm-up because the SCO link
    /// can take >1s to stabilize on AirPods specifically.
    private func prewarmAudioEngine() {
        // A meeting recording owns the microphone. Do not keep VoiceService's
        // background warm-up tap alive while the meeting mic engine is active.
        guard keyboardListenerRef?.isMeetingActive != true else {
            debugLog("Pre-warm skipped — meeting recording owns the microphone")
            return
        }
        let isBluetooth = Self.isCurrentInputBluetooth()
        let warmDuration = prewarmDuration
        debugLog("Pre-warming audio engine (\(isBluetooth ? "Bluetooth" : "wired/built-in"), duration=\(warmDuration)s)")
        Task { @MainActor in
            do {
                let engine = AVAudioEngine()

                // Same off-main HAL handling as startAudioEngine — pre-warm must
                // never freeze the UI either (it runs at launch and after each
                // keep-alive expiry).
                let format: AVAudioFormat = await Task.detached(priority: .userInitiated) {
                    engine.inputNode.outputFormat(forBus: 0)
                }.value
                guard format.sampleRate > 0 else { return }

                engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in }
                try await Task.detached(priority: .userInitiated) { try engine.start() }.value

                DispatchQueue.main.asyncAfter(deadline: .now() + warmDuration) {
                    // Stop before removeTap — see stopAudioEngineImmediately().
                    engine.stop()
                    engine.inputNode.removeTap(onBus: 0)
                }
            } catch {
                debugWarn("Audio pre-warm failed (non-fatal): \(error)")
            }
        }
    }

    /// Hand the microphone over to a meeting recording. VoiceService keeps its
    /// `AVAudioEngine` warm between voice inputs (keep-alive timer / focus
    /// warm-up), so the meeting drops that resident tap before starting its own
    /// long-running capture. Pre-warming stays suppressed via `isMeetingActive`
    /// until the meeting ends.
    func releaseAudioEngineForMeeting() {
        engineKeepAliveTimer?.invalidate()
        engineKeepAliveTimer = nil
        isFocusWarmEngaged = false
        stopAudioEngineImmediately()
        debugLog("Released audio engine — microphone handed to meeting recording")
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

    /// Running peak used to drive a streaming-AGC view of the waveform. Mirrors
    /// the batch AGC in `transcribeAndInject` (which scales the whole utterance
    /// by `min(0.6 / peak, 40)`) so the bars reflect the level ASR will actually
    /// receive — a built-in mic gets pulled up, AirPods stay natural, no
    /// per-device tuning. Decays slowly so a transient pop can't suppress the
    /// rest of the recording.
    private var streamingPeak: Float = 0

    /// Cold-starts (or reuses) the capture engine. The CoreAudio HAL queries it
    /// issues — the first `inputNode` access and `engine.start()` — can block on
    /// a synchronous `mach_msg` to coreaudiod for tens of seconds when the audio
    /// daemon is busy. Those two calls run on a detached task so the main actor
    /// stays responsive while the device/daemon settles; everything else stays
    /// on the main actor so the (unchanged) tap closure keeps its isolation.
    private func startAudioEngine() async throws {
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

        // First `inputNode` access triggers AVAudioEngine's UpdateInputNode →
        // CoreAudio HAL GetHWFormat, a synchronous mach_msg to coreaudiod. Run
        // it off the main thread: a slow/wedged coreaudiod then merely delays
        // the recording instead of freezing the whole UI for tens of seconds.
        let format: AVAudioFormat = await Task.detached(priority: .userInitiated) {
            engine.inputNode.outputFormat(forBus: 0)
        }.value
        let inputNode = engine.inputNode
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

        // 某些场景下系统会把输入切到 VPIO 多通道模式（如微信通话，本机 9 ch），
        // 这种格式没有标准 channel layout，AVAudioConverter 无法把它降混成单声道
        // （会输出全 0）。所以转换器只负责采样率转换：源格式固定为「单声道 + 设备
        // 采样率」，降混由 tap 里自己取 channel 0（普通模式下 ch0 即麦克风信号）。
        let monoSourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: monoSourceFormat, to: targetFormat) else {
            debugLog("Failed to create audio converter from \(monoSourceFormat) to \(targetFormat)")
            throw NSError(domain: "VoiceService", code: -2, userInfo: [NSLocalizedDescriptionKey: "音频格式转换器创建失败"])
        }

        // Capture targetFormat and converter for the tap closure
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.incrementTapFireCount()
            guard self.isRecording else { return }

            // Compute RMS audio level from raw buffer for waveform animation + leading-silence detection
            var rawRMS: Float = 0
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = Int(buffer.frameLength)
                var sum: Float = 0
                var bufferPeak: Float = 0
                for i in 0..<frameLength {
                    let s = channelData[i]
                    sum += s * s
                    let a = abs(s)
                    if a > bufferPeak { bufferPeak = a }
                }
                rawRMS = sqrtf(sum / Float(max(frameLength, 1)))
                // Streaming AGC — same shape as the batch AGC in
                // transcribeAndInject (gain = min(0.6 / peak, 40)). Decay factor
                // 0.995 per buffer ≈ 3 s half-life at typical buffer rates, so a
                // transient pop doesn't lock the gain low for the rest of the
                // utterance. The waveform now shows what ASR will actually hear.
                self.streamingPeak = max(bufferPeak, self.streamingPeak * 0.995)
                let gain: Float = self.streamingPeak > 0
                    ? min(Float(0.6) / self.streamingPeak, Float(40))
                    : 1
                let gainedRMS = rawRMS * gain
                let dB = 20 * log10(max(gainedRMS, 1e-6))
                // Post-AGC window: speech RMS sits around -20 ~ -10 dBFS once the
                // gain converges (peak pinned to 0.6 ≈ -4.4 dBFS, crest factor
                // ~12-15 dB). Mapping [-50, -10] → [0, 1] keeps quiet gaps low
                // and active speech filling most of the bar.
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

            // VPIO 给的是多通道 buffer（各通道内容完全相同），先手动取 channel 0
            // 拼成单声道 buffer，再交给转换器做 48k→16k 采样率转换。
            guard buffer.frameLength > 0, let srcChannel = buffer.floatChannelData?[0] else { return }
            guard let monoBuffer = AVAudioPCMBuffer(
                pcmFormat: monoSourceFormat,
                frameCapacity: buffer.frameLength
            ) else {
                DebugLog.write("[VoiceService] Audio tap: FAILED to allocate mono buffer")
                return
            }
            monoBuffer.frameLength = buffer.frameLength
            memcpy(monoBuffer.floatChannelData![0], srcChannel,
                   Int(buffer.frameLength) * MemoryLayout<Float>.size)

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
                return monoBuffer
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

        // engine.start() spins up the CoreAudio IO thread — also a synchronous
        // HAL round-trip that can stall on a busy coreaudiod. Off the main
        // thread for the same reason as the inputNode query above.
        try await Task.detached(priority: .userInitiated) { try engine.start() }.value
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
                await self.attemptAudioEngineRecovery(reason: "AVAudioEngineConfigurationChange (device format changed mid-recording)")
            }
        }
    }

    /// Tear down the current engine and rebuild it once. Used both as a fast retry
    /// when the first engine failed to deliver any samples (mic was occupied at
    /// startup) and as a recovery from `AVAudioEngineConfigurationChange` (another
    /// app released the device mid-recording, system flipped formats).
    private func attemptAudioEngineRecovery(reason: String) async {
        guard isRecording else { return }
        ASRLogger.shared.event(.audioEngineRecoveryAttempt, sessionID: currentSessionID,
                               props: ["reason": reason,
                                       "alreadyAttempted": audioRecoveryAttempted])
        guard !audioRecoveryAttempted else {
            debugLog("Audio engine recovery skipped — already attempted this session (\(reason))")
            return
        }
        audioRecoveryAttempted = true
        debugLog("Audio engine recovery: rebuilding engine — \(reason)")
        stopAudioEngineImmediately()
        do {
            try await startAudioEngine()
            // The recording may have ended (key release / ESC / meeting) during
            // the rebuild's cold-start await — don't leave a resurrected engine.
            guard isRecording else {
                debugLog("Audio engine recovery: recording ended during rebuild — releasing engine")
                stopAudioEngineImmediately()
                return
            }
            debugLog("Audio engine recovery: rebuild succeeded")
        } catch {
            debugError("Audio engine recovery: rebuild FAILED: \(error) — health check will abort if still no audio")
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
            // Order matters: stop the engine BEFORE removing the tap.
            // `stop()` quiesces the CoreAudio IO thread; only then is it safe
            // for `removeTap` to release the tap closure (and the
            // AVAudioConverter it captures). The reverse order races the IO
            // thread — it can dereference the just-freed converter and jump to
            // a null callback (EXC_BAD_ACCESS / SIGSEGV on the audio thread).
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
    }

    // MARK: - Transcription

    /// Process cloud streaming result and inject text.
    private func processAndInject(text: String, chunks: [Data]) async {
        // No hide() here — handleKeyRelease already hid the overlay the
        // instant the user let go. Error paths re-show via showBriefMessage.

        let session = currentSessionID
        ASRLogger.shared.event(.finalReceived, sessionID: session,
                               props: ["engine": "volcano", "len": text.count])

        guard !text.isEmpty else {
            ASRLogger.shared.event(.asrFinished, sessionID: session,
                                   props: ["empty": true])
            state = .ready
            return
        }

        // Learned correction rules (自学习纠错) are merged AFTER the user's
        // manual rules. If the learning subsystem is empty/disabled this is
        // just the manual list — behaviour is unchanged.
        CorrectionLearningEngine.shared.noteTranscription(rawText: text)
        ASRLogger.shared.event(.processStarted, sessionID: session)
        var processedText = TextProcessor.process(
            text: text,
            removeFillers: configManager.removeFillers,
            rules: configManager.replacements + CorrectionLearningEngine.shared.activeRules
        )
        ASRLogger.shared.event(.processCompleted, sessionID: session,
                               props: ["len": processedText.count])

        guard !processedText.isEmpty else {
            state = .ready
            return
        }

        state = .ready

        // LLM polish
        let notes = configManager.localLLMNotes
        let polisher: (any TextPolisher)?

        if configManager.cloudLLMEnabled,
           let provider = LLMProvider(rawValue: configManager.llmProvider),
           provider != .none {
            let creds = configManager.llmCredentials[provider.rawValue] ?? ProviderCredentials()
            // 抄豆包：把场景 + 最近历史 + 热词 + 自学习词 + 英文术语都喂给 LLM polish。
            let polishContext = await buildPolishContext(notes: notes)
            polisher = LLMClient(provider: provider, credentials: creds, polishContext: polishContext)
        } else {
            polisher = nil
        }

        if let polisher, polisher.shouldPolish(processedText) {
            let polishStart = Date()
            ASRLogger.shared.event(.llmPolishStarted, sessionID: session,
                                   props: ["provider": configManager.llmProvider])
            do {
                let polished = try await polisher.polish(processedText)
                let changed = !polished.isEmpty && polished != processedText
                if changed { processedText = polished }
                ASRLogger.shared.event(.llmPolishCompleted, sessionID: session,
                                       props: ["dur_ms": ASRLogger.durMs(since: polishStart),
                                               "changed": changed])
            } catch {
                // Polish failure shouldn't block injection — the raw (but
                // already filler-removed + replacements-applied) text is still
                // useful. But we surface the error so debugging is possible
                // instead of silently dropping the call.
                debugWarn("Polish failed: \(error.localizedDescription)")
                print("[VoiceService] LLM polish failed: \(error)")
                ASRLogger.shared.event(.llmPolishFailed, sessionID: session,
                                       props: ["dur_ms": ASRLogger.durMs(since: polishStart),
                                               "error": "\(error.localizedDescription)"])
            }
        }

        await injectFinalText(processedText, session: session, engineName: "volcano")
        playEndSound()

        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        // Keep raw ASR alongside processed output — the self-learning engine
        // diffs (raw → user edit) so it learns ASR mistakes, not LLM polish.
        let record = TranscriptionRecord(text: processedText, duration: duration, rawText: text, model: loadedModelLabel)
        Task { await historyStore.insert(record) }
        // Voice input just completed — History tab opens on this segment next.
        configManager.lastHistoryKind = "voice"
    }

    /// Final-text injection with mode-aware dispatch. `typewriterMode == true`
    /// rolls the text out one character at a time via CGEvent unicode keystrokes
    /// (clipboard untouched); `false` keeps the existing single Cmd+V paste.
    /// Centralised here so both the cloud-streaming path and the local-batch
    /// path share identical sequencing — same ASRLogger events, same dispatch.
    private func injectFinalText(_ processed: String,
                                 session: UUID?,
                                 engineName: String) async {
        ASRLogger.shared.event(.injectStarted, sessionID: session,
                               props: ["len": processed.count,
                                       "mode": configManager.typewriterMode ? "typewriter" : "paste",
                                       "engine": engineName])
        if configManager.typewriterMode {
            // 浮窗只显示波形,不预览识别文字。它从松手一直留到这里,
            // 键盘逐字键入完成后隐藏。
            await Task.detached(priority: .userInitiated) {
                TextInjector.typeTextProgressive(processed)
            }.value
            RecordingOverlayPanel.shared.hide()
            ASRLogger.shared.event(.panelHidden, sessionID: session,
                                   props: ["reason": "typewriter_done"])
        } else {
            TextInjector.typeText(processed, preserveClipboard: configManager.preserveClipboard)
        }
        ASRLogger.shared.event(.injectCompleted, sessionID: session)
    }

    private func transcribeAndInject(chunks: [Data]) async {
        // No defer { hide() } — the overlay was already hidden the moment
        // the user released the key. Only the error paths below need to
        // re-surface it via showBriefMessage.

        debugLog("transcribeAndInject: chunks=\(chunks.count), totalBytes=\(chunks.reduce(0) { $0 + $1.count })")

        guard !chunks.isEmpty else {
            debugLog("transcribeAndInject SKIPPED: chunks empty — mic delivered no audio")
            RecordingOverlayPanel.shared.showBriefMessage("麦克风无输入，可能被其他 app 占用")
            state = .ready
            return
        }

        guard let engine = asrEngine else {
            debugLog("transcribeAndInject SKIPPED: asrEngine is nil")
            state = .error("模型未加载")
            return
        }

        var allSamples = mergeAudioSamples(from: chunks)

        guard !allSamples.isEmpty else {
            debugLog("transcribeAndInject SKIPPED: allSamples empty after merge (skipSamples=\(skipSamples))")
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
        // Reject only genuinely-dead input (RMS ~0 = the mic delivered all-zero
        // buffers, e.g. held by another app feeding silence). Quiet speech — a
        // built-in mic is naturally low-level — is NOT rejected here; it gets
        // normalised up just below.
        guard rms > 0.0002 else {
            debugLog("transcribeAndInject SKIPPED: silent audio, RMS=\(rms), samples=\(allSamples.count)")
            RecordingOverlayPanel.shared.showBriefMessage("麦克风无输入，可能被其他 app 占用")
            state = .ready
            return
        }

        // Software AGC — replaces the VPIO/AGC path, which cost ~hundreds of ms
        // of cold-start latency on every key press. The built-in mic delivers a
        // very low-level signal (~-56 dBFS); scale the whole utterance up by peak
        // so the ASR model gets a healthy level. The gain is capped so we never
        // clip, and an already-hot signal (AirPods) is left essentially untouched
        // (gain ≈ 1, and we never attenuate).
        let peak = allSamples.reduce(Float(0)) { max($0, abs($1)) }
        if peak > 0 {
            let gain = min(Float(0.6) / peak, Float(40))
            if gain > 1.05 {
                for i in allSamples.indices { allSamples[i] *= gain }
                debugLog("Software AGC: peak=\(String(format: "%.4f", peak)) → gain=\(String(format: "%.1f", gain))x")
            }
        }
        let gainedRMS = sqrt(allSamples.reduce(0) { $0 + $1 * $1 } / Float(allSamples.count))
        debugLog("transcribeAndInject: samples=\(allSamples.count), RMS=\(String(format: "%.4f", rms))→\(String(format: "%.4f", gainedRMS)), duration=\(String(format: "%.1f", Double(allSamples.count) / 16000.0))s")

        // Build hotwords context string
        let hotwords = configManager.hotwords
        let capturedContext = Self.buildHotwordContext(hotwords, appName: recordingAppContext)

        // Apple's recognizer is locale-bound and cannot auto-detect, so pass the
        // user's chosen voice-input language. Qwen3-ASR is multilingual — keep
        // nil so it auto-detects (pinning a hint forced Japanese/English speech
        // into Mandarin homophone mode).
        let asrLanguage: String? = (engine is AppleASREngine || engine is OpenAIWhisperASREngine)
            ? configManager.voiceInputLanguage.asrLanguageHint
            : nil

        let session = currentSessionID
        let engineName = String(describing: type(of: engine))
        ASRLogger.shared.event(.asrStarted, sessionID: session,
                               props: ["engine": engineName,
                                       "samples": allSamples.count,
                                       "lang": asrLanguage ?? "auto"])
        let asrStart = Date()
        // Run transcription on background thread to keep UI responsive.
        let transcribeTask = Task.detached { [engine] in
            let result = engine.transcribe(
                audio: allSamples,
                sampleRate: 16000,
                language: asrLanguage,
                context: capturedContext
            )
            // Drop MLX intermediate buffers from the recycle pool. Variable
            // audio lengths produce variable-shape intermediates that the pool
            // cannot reuse, so without this they accumulate indefinitely.
            MLXMemoryGovernor.reclaim()
            return result
        }
        currentTranscribeTask = transcribeTask

        // Race the transcribe against a hard timeout. The MLX call itself is
        // synchronous and not cancellable, so when the timeout wins we just
        // abandon the orphan task — it will finish on its own and its result
        // is discarded.
        let timeoutNs = Self.transcribeTimeoutSeconds * 1_000_000_000
        let textOpt: String? = await withTaskGroup(of: String?.self) { group -> String? in
            group.addTask { await transcribeTask.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNs)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let text = textOpt else {
            currentTranscribeTask = nil
            ASRLogger.shared.event(.asrFailed, sessionID: session,
                                   props: ["engine": engineName,
                                           "dur_ms": ASRLogger.durMs(since: asrStart),
                                           "reason": "timeout",
                                           "timeout_s": Self.transcribeTimeoutSeconds])
            debugError("transcribeAndInject TIMEOUT after \(Self.transcribeTimeoutSeconds)s — MLX likely wedged (long idle?). Reload model to recover.")
            RecordingOverlayPanel.shared.showBriefMessage("识别超时，请重新切换模型试试")
            state = .ready
            return
        }
        currentTranscribeTask = nil

        ASRLogger.shared.event(.finalReceived, sessionID: session,
                               props: ["engine": engineName,
                                       "dur_ms": ASRLogger.durMs(since: asrStart),
                                       "len": text.count,
                                       "empty": text.isEmpty])
        debugLog("ASR raw result: \"\(text)\" (empty=\(text.isEmpty)) — \(MLXMemoryGovernor.snapshotDescription())")

        // Process text (Layer 1 filler removal + Layer 2 ITN + replacements).
        // Learned correction rules (自学习纠错) are merged after the user's
        // manual rules; an empty/failed learning store leaves behaviour unchanged.
        CorrectionLearningEngine.shared.noteTranscription(rawText: text)
        ASRLogger.shared.event(.processStarted, sessionID: session)
        var processedText = TextProcessor.process(
            text: text,
            removeFillers: configManager.removeFillers,
            rules: configManager.replacements + CorrectionLearningEngine.shared.activeRules
        )
        ASRLogger.shared.event(.processCompleted, sessionID: session,
                               props: ["len": processedText.count])
        debugLog("After TextProcessor: \"\(processedText)\"")

        let isHotwordHallucination = Self.isLikelyHotwordHallucination(processedText, hotwords: hotwords)
        let isSilenceHallucination = Self.isLikelySilenceHallucination(processedText)

        guard !processedText.isEmpty, !isHotwordHallucination, !isSilenceHallucination else {
            debugLog("transcribeAndInject SKIPPED: processedText empty=\(processedText.isEmpty), isHotwordHallucination=\(isHotwordHallucination), isSilenceHallucination=\(isSilenceHallucination)")
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

        if configManager.cloudLLMEnabled,
           let provider = LLMProvider(rawValue: configManager.llmProvider),
           provider != .none {
            let creds = configManager.llmCredentials[provider.rawValue] ?? ProviderCredentials()
            NSLog("[VoiceService] LLM polish (cloud/%@): input=\"%@\", notes=\"%@\"", provider.rawValue, processedText, notes)
            // 把当前场景 + 最近 3 条历史 + 热词 + 自学习词 + 英文术语词典一并喂给 LLM。
            let polishContext = await buildPolishContext(notes: notes)
            polisher = LLMClient(provider: provider, credentials: creds, polishContext: polishContext)
        } else {
            polisher = nil
            NSLog("[VoiceService] LLM polish: skipped (not configured or model not ready)")
        }

        if let polisher, polisher.shouldPolish(processedText) {
            let polishStart = Date()
            ASRLogger.shared.event(.llmPolishStarted, sessionID: session,
                                   props: ["provider": configManager.llmProvider])
            do {
                let polished = try await polisher.polish(processedText)
                let changed = !polished.isEmpty && polished != processedText
                if changed {
                    NSLog("[VoiceService] LLM polish: output=\"%@\"", polished)
                    processedText = polished
                } else {
                    NSLog("[VoiceService] LLM polish: no change")
                }
                ASRLogger.shared.event(.llmPolishCompleted, sessionID: session,
                                       props: ["dur_ms": ASRLogger.durMs(since: polishStart),
                                               "changed": changed])
            } catch {
                NSLog("[VoiceService] LLM polish failed: %@", String(describing: error))
                ASRLogger.shared.event(.llmPolishFailed, sessionID: session,
                                       props: ["dur_ms": ASRLogger.durMs(since: polishStart),
                                               "error": "\(error.localizedDescription)"])
            }
        }

        // Inject text. In typewriter mode the overlay (waveform only) was kept
        // open since key-release; injectFinalText hides it once typing finishes.
        await injectFinalText(processedText, session: session, engineName: engineName)
        playEndSound()

        // Record to history (keep raw ASR alongside processed output so the
        // self-learning engine has a real "before" side for diffing).
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let record = TranscriptionRecord(text: processedText, duration: duration, rawText: text, model: loadedModelLabel)
        Task { await historyStore.insert(record) }
        // Voice input just completed — History tab opens on this segment next.
        configManager.lastHistoryKind = "voice"
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

    /// 给云端 LLM polish 打包当前上下文：场景、最近历史、热词、自学习词、英文术语词典。
    /// 历史只取最近 3 条 polished 文本——HistoryStore.fetchAll 拿到的就是 polished 版本，
    /// prompt 里标注「可能含错」让 LLM 不被过往错字强化。空历史不会留空段。
    private func buildPolishContext(notes: String) async -> PolishContext {
        let recent = await historyStore.fetchAll(limit: 3)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // 自学习词取 active rules 的目标词（`to`）——用户实际想要的拼写。
        let learned = CorrectionLearningEngine.shared.activeRules.map { $0.to }
        return PolishContext(
            userNotes: notes,
            appContext: recordingAppContext,
            recentHistory: recent,
            hotwords: configManager.hotwords,
            learnedTerms: learned,
            techLexicon: TechLexicon.defaults
        )
    }

    /// Captures the frontmost non-VoiceBrother app's localized name. Returns nil
    /// when the frontmost app is our own process (panel focus edge case).
    static func captureFrontmostAppName() -> String? {
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

    /// WARN/ERROR variants so real incidents surface via `grep ERROR` instead
    /// of hiding in the INFO stream. Same `[VoiceService]` prefix.
    private func debugWarn(_ message: String) {
        DebugLog.warn("[VoiceService] \(message)")
    }

    private func debugError(_ message: String) {
        DebugLog.error("[VoiceService] \(message)")
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
}
