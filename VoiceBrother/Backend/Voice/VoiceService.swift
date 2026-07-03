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
///
/// This type is a facade: it owns the `@Published` UI state, the keyboard/focus
/// wiring, and the key-event handlers, and delegates the heavy lifting to four
/// collaborators it holds strongly — `VoiceAudioChunkStore` (thread-safe audio
/// buffer), `AudioEngineController` (AVAudioEngine lifecycle + tap + recovery),
/// `TranscriptionPipeline` (ASR → text → inject → history), and
/// `FeedbackSoundPlayer` (start/end cues).
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
    /// Recording HUD, injected as a Shared-layer abstraction so the backend
    /// depends on `OverlayPresenting`, not the concrete Frontend panel.
    let overlay: OverlayPresenting
    private let historyStore = HistoryStore()
    private var llmWarmupCancellable: AnyCancellable?

    /// Callback to toggle meeting recording, set by the app after MeetingService is created.
    var meetingToggleAction: (() -> Void)?

    // MARK: - Collaborators

    /// Thread-safe buffer of captured audio chunks. Written by the audio tap
    /// (via `audioController`) and read by the transcription pipeline.
    private let audioChunkStore = VoiceAudioChunkStore()
    /// Start/end feedback cues.
    private let feedbackPlayer = FeedbackSoundPlayer()
    /// AVAudioEngine capture lifecycle. Created in `init` (needs a back-ref to self).
    private var audioController: AudioEngineController!
    /// ASR → text-processing → injection → history. Created in `init`.
    private var transcriptionPipeline: TranscriptionPipeline!

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
    var currentTranscribeTask: Task<String, Never>?
    private var keyboardListener: KeyboardListener?

    /// Recording flag protected by a lock for thread-safe access from audio tap callback.
    private var _isRecording = false
    private let isRecordingLock = NSLock()

    /// Thread-safe getter/setter for isRecording.
    var isRecording: Bool {
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
    var isCapturingTail: Bool {
        get { isCapturingTailLock.withLock { _isCapturingTail } }
        set { isCapturingTailLock.withLock { _isCapturingTail = newValue } }
    }

    /// Tail-capture window, in milliseconds. Aggressive setting: trades the
    /// last ~50–100 ms of trailing audio for snappier text appearance. Most
    /// casual releases happen after the final syllable is articulated, so the
    /// shortened window rarely clips. Increase to 200–250 if trailing words
    /// start getting cut.
    private static let tailCaptureMillis: UInt64 = 150

    /// Timestamp when recording started, used to compute duration for history.
    var recordingStartTime: Date?

    /// UUID identifying the current voice session, used as the `session` field
    /// in `ASRLogger` events so a `tail -f /tmp/vb_asr_events.log` can be
    /// filtered to one press. Refreshed in `handleKeyPress`; never cleared so
    /// late events (e.g. inject_completed after a quick second press) still
    /// carry the press they belong to.
    var currentSessionID: UUID?

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

    /// True while a cold engine start is in flight. `startAudioEngine()` now
    /// awaits its CoreAudio HAL calls off the main thread (so a wedged
    /// coreaudiod can't freeze the UI), which means it can suspend. This flag
    /// serializes the cold-start path: a second key press / focus warm-up while
    /// one start is still in flight is rejected rather than racing a second
    /// `AVAudioEngine` onto the same microphone. Only touched on the main actor.
    private var isStartingEngine = false

    /// Tracks in-flight transcription/finalize work so we can await completion
    /// before yielding the shared ASR engine to the meeting service. The engine
    /// is not thread-safe; running voice and meeting transcribe concurrently
    /// on the same model will corrupt results or crash.
    private var pendingASRTask: Task<Void, Never>?

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
    var recordingAppContext: String?

    init(configManager: ConfigManager, overlay: OverlayPresenting = RecordingOverlayPanel.shared) {
        self.configManager = configManager
        self.overlay = overlay
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

        self.audioController = AudioEngineController(chunkStore: audioChunkStore, voice: self)
        self.transcriptionPipeline = TranscriptionPipeline(
            voice: self,
            configManager: configManager,
            historyStore: historyStore,
            chunkStore: audioChunkStore,
            feedbackPlayer: feedbackPlayer
        )
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
        audioController.prewarmAudioEngine()
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
            overlay.hide()
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
        audioController.prewarmAudioEngine()
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
        audioController.prewarmAudioEngine()
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
        audioController.stopAudioEngineImmediately()

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
        guard AudioEngineController.isCurrentInputBluetooth() else { return }
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
        if let engine = audioController.audioEngine, engine.isRunning {
            audioController.engineKeepAliveTimer?.invalidate()
            audioController.engineKeepAliveTimer = nil
            audioController.engineWarmKept = true
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
            try await audioController.startAudioEngine()
            // A meeting may have grabbed the mic, or focus may have moved away,
            // during the cold-start await — don't leave a resurrected engine.
            guard isFocusWarmEngaged, keyboardListenerRef?.isMeetingActive != true else {
                debugLog("Focus warm-up: state changed during cold start — releasing engine")
                audioController.stopAudioEngineImmediately()
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
        guard let engine = audioController.audioEngine, engine.isRunning else { return }
        guard audioController.engineKeepAliveTimer == nil else { return }
        debugLog("Focus warm-up: releasing — keep-alive timer will hold engine for \(audioController.keepAliveAfterRecording)s")
        audioController.stopAudioEngine()
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
                               props: ["bluetooth": AudioEngineController.isCurrentInputBluetooth()])

        isRecording = true
        audioChunkStore.clearAudioChunks()
        audioController.tapFireCount = 0
        audioController.hasReceivedRealAudio = false  // gate that skips Bluetooth SCO warm-up zeros
        audioController.streamingPeak = 0
        audioController.audioRecoveryAttempted = false
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
                try await audioController.startAudioEngine()

                // The user may have released the key, hit ESC, or started a
                // meeting during the cold-start await. If this session is no
                // longer the active one, tear the just-built engine down rather
                // than resurrecting a recording that was already finalized.
                guard currentSessionID == session, isRecording, !isCapturingTail else {
                    debugLog("handleKeyPress: session no longer active after engine start — discarding engine")
                    audioController.stopAudioEngineImmediately()
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

                overlay.show()
                ASRLogger.shared.event(.panelPresentRecording, sessionID: session)
                feedbackPlayer.playStartSound()

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
                let healthTimeout = audioController.audioHealthCheckTimeout
                audioHealthCheckTimer?.invalidate()
                audioHealthCheckTimer = Timer.scheduledTimer(withTimeInterval: healthTimeout, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        guard self.isRecording, self.recordingStartTime == sessionStart else { return }
                        guard self.audioController.tapFireCount == 0 else { return }
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
                        guard self.audioController.tapFireCount == 0, !self.audioController.audioRecoveryAttempted else { return }
                        await self.audioController.attemptAudioEngineRecovery(reason: "no audio after \(recoveryDelay)s")
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
                audioController.tapFireCount = 0
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
        audioController.stopAudioEngineImmediately()
        audioChunkStore.clearAudioChunks()
        (asrEngine as? VolcanoASREngine)?.cancelStreaming()
        overlay.showBriefMessage(message)
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
                               props: ["rec_ms": recDuration, "taps": audioController.tapFireCount,
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
            overlay.hide()
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

        let chunks = audioChunkStore.swapAudioChunks()
        let engineRunning = audioController.audioEngine?.isRunning ?? false
        audioController.stopAudioEngine()
        // If focus is still on a text-editable field, hold the engine open instead
        // of letting the keep-alive expire. The keep-alive timer is the right
        // baseline when the user finishes recording and moves on, but here the
        // FocusObserver tells us they're still in a "ready to dictate" context.
        if isFocusWarmEngaged {
            audioController.engineKeepAliveTimer?.invalidate()
            audioController.engineKeepAliveTimer = nil
            audioController.engineWarmKept = true
            debugLog("finalizeRecordingAfterTail: holding engine — text field still focused")
        }
        let recordDuration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        debugLog("finalizeRecordingAfterTail: chunks=\(chunks.count), totalBytes=\(chunks.reduce(0) { $0 + $1.count }), duration=\(String(format: "%.1f", recordDuration))s, tapFired=\(audioController.tapFireCount), engineRunning=\(engineRunning)")

        state = .transcribing

        // Cloud streaming: finish and get result immediately (audio already sent)
        if let volcEngine = asrEngine as? VolcanoASREngine, volcEngine.isStreaming {
            pendingASRTask = Task { @MainActor in
                let text = await Task.detached { volcEngine.finishStreaming() }.value
                await self.transcriptionPipeline.processAndInject(text: text, chunks: chunks)
            }
        } else {
            pendingASRTask = Task { @MainActor in
                await transcriptionPipeline.transcribeAndInject(chunks: chunks)
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
        audioController.stopAudioEngineImmediately()

        audioChunkStore.clearAudioChunks()

        // Cancel cloud streaming if active
        (asrEngine as? VolcanoASREngine)?.cancelStreaming()

        overlay.hide()
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
            audioController.stopAudioEngineImmediately()
            audioChunkStore.clearAudioChunks()
            overlay.hide()
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

    /// Hand the microphone over to a meeting recording. VoiceService keeps its
    /// `AVAudioEngine` warm between voice inputs (keep-alive timer / focus
    /// warm-up), so the meeting drops that resident tap before starting its own
    /// long-running capture. Pre-warming stays suppressed via `isMeetingActive`
    /// until the meeting ends.
    func releaseAudioEngineForMeeting() {
        audioController.engineKeepAliveTimer?.invalidate()
        audioController.engineKeepAliveTimer = nil
        isFocusWarmEngaged = false
        audioController.stopAudioEngineImmediately()
        debugLog("Released audio engine — microphone handed to meeting recording")
    }

    // MARK: - Frontmost App Context

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

    /// Toggle meeting-active suppression from MeetingService via the protocol
    /// instead of reaching into `keyboardListenerRef` directly.
    func setMeetingActive(_ active: Bool) {
        keyboardListenerRef?.isMeetingActive = active
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
}
