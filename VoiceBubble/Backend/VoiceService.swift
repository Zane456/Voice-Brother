import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Foundation
import Qwen3ASR

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

    private(set) var asrModel: Qwen3ASRModel?
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

    // Background model download
    private var backgroundDownloadTask: Task<Void, Never>?

    /// Timestamp when recording started, used to compute duration for history.
    private var recordingStartTime: Date?

    /// Safety timer to auto-stop recording after 120 seconds.
    private var safetyTimer: Timer?

    /// Number of audio samples to skip at the start of recording (400ms at 16kHz).
    private let skipSamples = 6400

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

                // 2. Determine model
                let modelString = configManager.model
                let hfId = resolveHuggingFaceId(modelString)

                // 3. Download + load model
                state = .downloading
                let model = try await Qwen3ASRModel.fromPretrained(
                    modelId: hfId,
                    progressHandler: { [weak self] progress, status in
                        Task { @MainActor in
                            self?.handleDownloadProgress(progress: progress, status: status)
                        }
                    }
                )

                guard !Task.isCancelled else { return }

                // 4. Load complete
                self.asrModel = model
                state = .ready

                // 5. Start keyboard listener
                startKeyboardListener()

                // 6. Background download alternate model
                downloadAlternateModel(current: hfId)

            } catch {
                state = .error("启动失败: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        // Cancel safety timer
        safetyTimer?.invalidate()
        safetyTimer = nil

        // Cancel any background work
        backgroundDownloadTask?.cancel()
        backgroundDownloadTask = nil

        // Stop keyboard listener
        keyboardListener?.stop()
        keyboardListener = nil

        // Stop audio engine
        stopAudioEngine()

        // Unload ASR model
        if let model = asrModel {
            model.unload()
            asrModel = nil
        }

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
    }

    // MARK: - Key Event Handlers

    private func handleKeyPress() {
        guard state == .ready else { return }

        do {
            try startAudioEngine()
            isRecording = true
            clearAudioChunks()
            recordingStartTime = Date()
            state = .recording
            RecordingOverlayPanel.shared.show()

            // Safety timer: auto-stop after 120 seconds
            safetyTimer?.invalidate()
            safetyTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.handleKeyRelease()
                }
            }
        } catch {
            print("[VoiceService] Failed to start audio engine: \(error)")
            state = .ready
        }
    }

    private func handleKeyRelease() {
        guard isRecording else { return }
        isRecording = false
        safetyTimer?.invalidate()
        safetyTimer = nil

        let chunks = swapAudioChunks()
        stopAudioEngine()

        RecordingOverlayPanel.shared.hide()
        state = .transcribing

        Task { @MainActor in
            await transcribeAndInject(chunks: chunks)
        }
    }

    private func handleCancel() {
        guard isRecording || state == .recording else { return }
        isRecording = false
        safetyTimer?.invalidate()
        safetyTimer = nil

        clearAudioChunks()
        stopAudioEngine()

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
        // Cancel any in-progress voice recording
        if isRecording {
            isRecording = false
            stopAudioEngine()
            clearAudioChunks()
            RecordingOverlayPanel.shared.hide()
        }
        // Reset state back to ready so meeting can use the service
        if state == .recording || state == .transcribing {
            state = .ready
        }
        // Toggle the meeting service (which manages its own overlay show/hide)
        meetingToggleAction?()
    }

    // MARK: - Audio Engine

    private func startAudioEngine() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        let format = inputNode.outputFormat(forBus: 0)

        // We need 16kHz mono Float32 for the ASR model
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        let converter = AVAudioConverter(from: format, to: targetFormat)!

        // Capture targetFormat and converter for the tap closure
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            guard self.isRecording else { return }

            // Convert to 16kHz mono Float32
            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / format.sampleRate)
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: max(frameCount, 1)
            ) else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error else { return }

            // Extract float samples as Data
            if let channelData = convertedBuffer.floatChannelData {
                let floatCount = Int(convertedBuffer.frameLength)
                let data = Data(bytes: channelData[0], count: floatCount * MemoryLayout<Float>.size)
                self.appendAudioChunk(data)
            }
        }

        try engine.start()
        self.audioEngine = engine
    }

    private func stopAudioEngine() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
    }

    // MARK: - Transcription

    private func transcribeAndInject(chunks: [Data]) async {
        guard !chunks.isEmpty else {
            state = .ready
            return
        }

        guard let model = asrModel else {
            state = .error("模型未加载")
            return
        }

        // Merge audio chunks into a single Float array
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

        // Skip first 400ms (6400 samples at 16kHz) to avoid key press sound bleeding
        if allSamples.count > skipSamples {
            allSamples = Array(allSamples.dropFirst(skipSamples))
        }

        guard !allSamples.isEmpty else {
            state = .ready
            return
        }

        // Skip transcription for very short recordings (< 0.5 seconds at 16kHz)
        guard allSamples.count >= 8000 else {
            state = .ready
            return
        }

        // Skip transcription if audio is mostly silence/background noise
        let rms = sqrt(allSamples.map { $0 * $0 }.reduce(0, +) / Float(allSamples.count))
        guard rms > 0.03 else {
            print("[VoiceService] Skipping silent audio (RMS=\(rms))")
            state = .ready
            return
        }

        do {
            // Build hotwords context string
            let hotwords = configManager.hotwords
            let context = hotwords.joined(separator: " ")

            let text = try model.transcribe(
                audio: allSamples,
                sampleRate: 16000,
                language: "Chinese",
                context: context.isEmpty ? nil : context
            )

            // Process text
            let processedText = TextProcessor.process(
                text: text,
                removeFillers: removeFillers,
                rules: configManager.replacements
            )

            // Skip if the result consists entirely of hotwords (model hallucinated from context)
            // Break hotwords into individual tokens for matching (e.g., "Claude Code" → ["Claude", "Code"])
            var hotwordTokens = Set<String>()
            for word in hotwords {
                hotwordTokens.insert(word)
                for token in word.split(separator: " ").map(String.init) {
                    hotwordTokens.insert(token)
                }
            }
            var remaining = processedText.trimmingCharacters(in: .whitespacesAndNewlines)
            for token in hotwordTokens.sorted(by: { $0.count > $1.count }) {
                remaining = remaining.replacingOccurrences(of: token, with: "")
            }
            remaining = remaining.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let isOnlyHotwords = !processedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && remaining.isEmpty

            // Inject text if non-empty and not just hallucinated hotwords
            if !processedText.isEmpty && !isOnlyHotwords {
                TextInjector.typeText(processedText, preserveClipboard: configManager.preserveClipboard)

                // Record to history
                let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
                let record = TranscriptionRecord(text: processedText, duration: duration)
                Task { await historyStore.insert(record) }
            }

            state = .ready

        } catch {
            print("[VoiceService] Transcription failed: \(error)")
            // Don't go to error state -- go back to ready so user can try again
            state = .ready
        }
    }

    // MARK: - Download Progress

    private func handleDownloadProgress(progress: Double, status: String) {
        // Determine approximate total based on current model
        let currentModel = ASRModel(rawValue: configManager.model) ?? .large
        let approxTotal: Int64 = (currentModel == .small) ? 400_000_000 : 2_500_000_000
        let downloaded = Int64(progress * Double(approxTotal))
        downloadProgress = DownloadProgress(
            downloaded: downloaded,
            total: approxTotal,
            description: status
        )
    }

    // MARK: - Background Alternate Model Download

    private func downloadAlternateModel(current hfId: String) {
        let currentModel = ASRModel(rawValue: configManager.model) ?? .large
        let alternateModel: ASRModel
        switch currentModel {
        case .small:
            alternateModel = .large
        case .large:
            alternateModel = .small
        }

        let alternateHfId = alternateModel.huggingFaceId

        backgroundDownloadTask = Task {
            do {
                _ = try await Qwen3ASRModel.fromPretrained(
                    modelId: alternateHfId,
                    progressHandler: { _, _ in }
                )
                // Model is now cached; we don't keep it loaded to save memory.
            } catch {
                // Background download failure is non-critical
                print("[VoiceService] Background download of alternate model failed: \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func resolveHuggingFaceId(_ modelString: String) -> String {
        if let model = ASRModel(rawValue: modelString) {
            return model.huggingFaceId
        }
        return ASRModel.large.huggingFaceId
    }

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
