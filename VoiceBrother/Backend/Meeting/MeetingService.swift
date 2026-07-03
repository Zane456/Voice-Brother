import Accelerate
import AVFoundation
import Combine
import CoreMedia
import Foundation
import Qwen3ASR
import ScreenCaptureKit
import SpeechVAD

/// Meeting recording and transcription service.
/// Captures system audio + microphone, uses VAD-based segmentation,
/// transcribes each segment immediately, outputs Markdown with timestamps.
///
/// Facade over three phase-B collaborators — `MeetingTranscriptWriter`
/// (markdown/WAV + soft-merge), `MeetingSegmentTranscriber` (per-segment ASR)
/// and `MeetingRecordingLoop` (capture/mix/VAD). This type keeps all
/// @Published state, the meeting lifecycle (start/stop/toggle/cleanup), the
/// generation guards and the SCStreamOutput conformance.
@MainActor
final class MeetingService: NSObject, ObservableObject, MeetingServiceProtocol {

    // MARK: - Constants

    static let sampleRate: Double = 16000
    static let sckSampleRate: Double = 48000
    static let vadMinAccumulate: Double = 20.0   // seconds before looking for cut points
    static let vadSilenceThreshold: Double = 0.8 // seconds of silence to trigger cut
    static let vadForceCut: Double = 40.0        // seconds max before force cut
    static let vadOverlap: Double = 0.5          // seconds of overlap at boundaries
    static let targetRMS: Float = 0.05
    static let epsilon: Float = 1e-8

    // MARK: - Published State

    @Published var state: MeetingState = .idle
    @Published var elapsedSeconds: Int = 0
    @Published var savePath: String
    @Published var summaryError: String?
    /// Absolute path of the markdown file for the meeting currently being
    /// finalized. Non-nil only while `state` is `.finishing` / `.summarizing`;
    /// the History tab uses it to badge that file card as "生成中".
    @Published var processingMarkdownPath: String?
    /// Model load/download progress (0...1) while `state == .preparing`.
    /// nil once recording starts. Driven by `Qwen3ASRModel.fromPretrained`.
    @Published var prepareProgress: Double?

    // MARK: - Dependencies

    private let configManager: ConfigManager
    /// Recording HUD, injected as a Shared-layer abstraction so the backend
    /// depends on `OverlayPresenting`, not the concrete Frontend panel.
    let overlay: OverlayPresenting
    weak var voiceService: VoiceService?
    let summarizer: MeetingSummarizer

    // MARK: - Internal State

    var asrEngine: (any ASREngineProtocol)?
    var vadModel: SileroVADModel?
    var audioEngine: AVAudioEngine?
    var scStream: SCStream?
    /// Screen recorder for the current meeting — non-nil only while a meeting
    /// with screen recording enabled is in progress.
    var screenRecorder: MeetingScreenRecorder?
    nonisolated(unsafe) let audioBuffer = AudioChunkBuffer()
    var startTime: Date?
    private var elapsedTimer: Timer?
    private var recordingTask: Task<Void, Never>?
    var pendingTranscriptionTask: Task<Void, Never>?
    /// Watchdog that force-fails a meeting stranded in `.preparing` by a hung
    /// model load (e.g. a HuggingFace snapshot that never returns).
    private var loadWatchdog: Task<Void, Never>?
    /// Bumped on every `start()` and on every `.preparing`-state stop. The
    /// startup task checks it before mutating shared state, so a model load
    /// that hangs and only returns much later cannot clobber a meeting the
    /// user has since cancelled or restarted.
    private var startGeneration = 0

    /// UUID identifying the current meeting, used as the `session` field in
    /// `ASRLogger` events. Refreshed on each `start()`; never cleared so late
    /// events (segment_transcribed after .idle) still trace back.
    var currentSessionID: UUID?

    // MARK: - Collaborators (phase B split)
    //
    // The facade owns @Published state + lifecycle; these three carry the
    // extracted single-responsibility work. Built in `init` after `super.init`
    // and wired with a weak back-reference to this facade.

    /// Markdown transcript + WAV writer — owns all on-disk file state and the
    /// soft-merge paragraph state.
    private var transcriptWriter: MeetingTranscriptWriter!
    /// Per-segment ASR runner — feeds cleaned text back to the writer.
    private var segmentTranscriber: MeetingSegmentTranscriber!
    /// Capture + mixing + VAD segmentation loop.
    private var recordingLoop: MeetingRecordingLoop!

    /// Nonisolated recording flag for thread-safe access from SCStreamOutput callback.
    private nonisolated(unsafe) let recordingFlag = ThreadSafeFlag()

    /// Tracks the latest mic & system-audio levels so the overlay waveform is
    /// driven by whichever channel is actually carrying sound. The mic tap goes
    /// silent when the mic is occupied by another app (chunks=0), so the system
    /// audio path must be able to keep the waveform moving on its own.
    private nonisolated(unsafe) let audioLevelTracker = AudioLevelTracker()

    /// Thread-safe getter for isRecording.
    private var isRecording: Bool {
        get { recordingFlag.value }
        set { recordingFlag.value = newValue }
    }

    // MARK: - Init

    init(configManager: ConfigManager, voiceService: VoiceService,
         overlay: OverlayPresenting = RecordingOverlayPanel.shared) {
        self.configManager = configManager
        self.overlay = overlay
        self.voiceService = voiceService
        self.savePath = configManager.meetingSavePath
        self.summarizer = MeetingSummarizer(configManager: configManager)
        super.init()

        let writer = MeetingTranscriptWriter()
        self.transcriptWriter = writer
        let transcriber = MeetingSegmentTranscriber(writer: writer, configManager: configManager)
        transcriber.service = self
        self.segmentTranscriber = transcriber
        let loop = MeetingRecordingLoop(
            audioBuffer: audioBuffer,
            recordingFlag: recordingFlag,
            audioLevelTracker: audioLevelTracker,
            writer: writer,
            transcriber: transcriber,
            configManager: configManager
        )
        loop.service = self
        self.recordingLoop = loop
    }

    // MARK: - MeetingServiceProtocol

    func start() {
        guard state == .idle else { return }

        // Meetings always transcribe with their own local Qwen model, chosen
        // independently of voice input. The accessor already constrains this
        // to a valid Qwen model, so there's no invalid-config case to guard.
        let meetingModel = configManager.meetingASRModel

        savePath = configManager.meetingSavePath

        // Verify save directory is writable BEFORE we start capturing audio. If
        // this fails partway through recording the markdown writes silently
        // disappear and the user thinks the meeting was lost.
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: savePath, withIntermediateDirectories: true)
        } catch {
            state = .error("无法创建保存目录: \(error.localizedDescription)")
            return
        }
        guard fm.isWritableFile(atPath: savePath) else {
            state = .error("保存目录无写入权限: \(savePath)")
            return
        }

        summaryError = nil
        prepareProgress = nil
        elapsedSeconds = 0
        // Model load (and, on first use, download) happens before recording —
        // show the preparing state so the UI isn't unresponsive meanwhile.
        let session = UUID()
        currentSessionID = session
        ASRLogger.shared.event(.meetingPreparing, sessionID: session, scope: .meeting,
                               props: ["model": meetingModel.huggingFaceId])
        state = .preparing

        // Show the overlay the instant the gesture completes — before the
        // model load — so the user gets immediate feedback. It pulses in a
        // "loading" state and switches to the live waveform once recording
        // actually starts. Without this the bubble only appeared after the
        // multi-second model load, making the gesture feel unresponsive.
        self.overlay.show(mode: .meeting, preparing: true)

        // New meeting attempt — bump the generation token. The startup task
        // and the watchdog both capture `gen` and check it before mutating
        // shared state, so a hung load that returns late can't clobber a
        // meeting the user has since cancelled or restarted.
        startGeneration &+= 1
        let gen = startGeneration

        // Suppress single-key voice input for the whole meeting lifecycle —
        // avoids microphone contention and prevents a second ASR model from
        // being loaded while the meeting's own model is resident.
        voiceService?.setMeetingActive(true)
        // Drop any warm VoiceService input engine before the meeting owns the
        // mic. The meeting uses its own VPIO-enabled engine below.
        voiceService?.releaseAudioEngineForMeeting()

        // Watchdog: a hung HuggingFace snapshot or MLX contention can leave
        // the model load never returning, stranding the meeting in .preparing
        // forever (cancel() is a no-op — a hung load reaches no cancellation
        // checkpoint). Poll every 15s; if we're still .preparing with no
        // forward download progress for ~45s, force-fail to .error, which
        // toggle() can recover from. A genuinely-slow first download keeps
        // `prepareProgress` climbing, so it never trips this.
        loadWatchdog?.cancel()
        loadWatchdog = Task { @MainActor [weak self] in
            var lastProgress: Double = -1
            var stalledPolls = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
                guard let self, !Task.isCancelled,
                      self.startGeneration == gen, self.state == .preparing else { return }
                let p = self.prepareProgress ?? 0
                if p > lastProgress { lastProgress = p; stalledPolls = 0 }
                else { stalledPolls += 1 }
                if stalledPolls >= 3 {
                    DebugLog.error("[MeetingService] Model-load watchdog: no progress ~45s — forcing .error")
                    self.startGeneration &+= 1   // orphan the stuck startup task
                    self.recordingTask?.cancel()
                    self.recordingTask = nil
                    self.voiceService?.setMeetingActive(false)
                    self.prepareProgress = nil
                    self.overlay.hide()
                    self.state = .error("模型加载卡住，请重试")
                    return
                }
            }
        }

        recordingTask = Task { @MainActor in
            do {
                // Load the meeting's own Qwen engine. Unlike before — when the
                // meeting borrowed VoiceService's engine — this instance is
                // owned by the meeting and unloaded at finalize, so it costs
                // no memory between meetings.
                DebugLog.write("[MeetingService] start(): loading Qwen model \(meetingModel.huggingFaceId)")
                let qwenModel = try await Qwen3ASRModel.fromPretrained(
                    modelId: meetingModel.huggingFaceId,
                    progressHandler: { [weak self] progress, _ in
                        Task { @MainActor in self?.prepareProgress = progress }
                    }
                )

                // Orphan check: stop() / the watchdog bumps `startGeneration`
                // to disown a stuck load. Free the model we just got and exit
                // WITHOUT touching shared state — that recovery path already
                // reset everything (and may belong to a newer meeting now).
                guard self.startGeneration == gen else {
                    DebugLog.write("[MeetingService] startup task orphaned after Qwen load — discarding model")
                    qwenModel.unload()
                    return
                }
                DebugLog.write("[MeetingService] Qwen model loaded — loading VAD")
                // Hold the engine locally until we've confirmed still-owner —
                // assigning self.asrEngine early would clobber a newer meeting.
                let engine = QwenASREngine(model: qwenModel)

                // Load VAD model (small, loads quickly)
                let vad = try await SileroVADModel.fromPretrained(engine: .coreml)

                guard self.startGeneration == gen else {
                    DebugLog.write("[MeetingService] startup task orphaned after VAD load — discarding models")
                    engine.unload()
                    return
                }
                DebugLog.write("[MeetingService] VAD loaded — entering .recording")

                // Confirmed still-owner — commit to shared state and stand the
                // watchdog down (the load completed, nothing to guard).
                self.loadWatchdog?.cancel()
                self.loadWatchdog = nil
                self.asrEngine = engine
                self.vadModel = vad

                // Model ready — transition to recording. The elapsed timer and
                // the red-REC overlay only start now, so the model-load delay
                // isn't counted as meeting time.
                self.prepareProgress = nil
                self.startTime = Date()
                self.elapsedSeconds = 0
                ASRLogger.shared.event(.meetingRecording, sessionID: self.currentSessionID, scope: .meeting)
                self.state = .recording
                self.startElapsedTimer()
                // Overlay is already on screen (shown in .preparing) — just
                // switch its waveform from the loading pulse to live audio.
                self.overlay.beginRecording()

                // Initialize markdown file
                self.transcriptWriter.initMarkdown(startTime: self.startTime, savePath: self.savePath)

                // Start recording
                try await self.recordingLoop.runRecording()

            } catch {
                // If the watchdog / a stop() already recovered this meeting,
                // don't touch state — the error belongs to a disowned task.
                guard self.startGeneration == gen else {
                    DebugLog.error("[MeetingService] orphaned startup task error: \(error)")
                    return
                }
                self.loadWatchdog?.cancel()
                self.loadWatchdog = nil
                self.overlay.hide()
                self.state = .error("录制失败: \(error.localizedDescription)")
                await self.cleanup()
            }
        }
    }

    func stop() {
        switch state {
        case .preparing:
            // Model is still loading. cancel() alone is unreliable — a hung
            // HuggingFace snapshot / MLX load never reaches a cancellation
            // checkpoint, so the meeting would stay stranded in .preparing
            // forever and every later double-Command would be swallowed.
            // Instead: bump the generation token (orphans the startup task —
            // it discards whatever it eventually loads instead of mutating
            // state) and force state straight back to .idle. The gesture is
            // now always recoverable, even from a fully hung load.
            startGeneration &+= 1
            loadWatchdog?.cancel()
            loadWatchdog = nil
            recordingTask?.cancel()
            recordingTask = nil
            voiceService?.setMeetingActive(false)
            prepareProgress = nil
            self.overlay.hide()
            state = .idle
        case .recording:
            ASRLogger.shared.event(.meetingFinishing, sessionID: currentSessionID, scope: .meeting,
                                   props: ["segments": transcriptWriter.transcribedSegmentCount,
                                           "elapsed_s": elapsedSeconds])
            state = .finishing
            // Expose the in-progress markdown file so the History tab can
            // badge it as "生成中" until finalization + summarization finish.
            processingMarkdownPath = transcriptWriter.markdownFilePath
            isRecording = false
            stopElapsedTimer()

            // Hide recording indicator
            self.overlay.hide()

            // Keep meetingActive = true during finalization to prevent voice
            // input from grabbing the microphone. runRecording() sets it back
            // to false once finalization completes.
        default:
            break
        }
    }

    func toggle() {
        switch state {
        case .idle:
            start()
        case .preparing, .recording:
            stop()
        case .finishing, .summarizing:
            // Already finishing or summarizing, do nothing
            break
        case .error:
            // Reset to idle and try again
            state = .idle
            start()
        }
    }

    // MARK: - Elapsed Timer

    private func startElapsedTimer() {
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let start = self.startTime else { return }
                self.elapsedSeconds = Int(Date().timeIntervalSince(start))
                self.overlay.updateMeetingElapsed(self.elapsedSeconds)
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // MARK: - Waveform Level

    /// Map an RMS audio level to a 0...1 waveform height. Shared by the mic tap
    /// and the system-audio callback so the overlay looks identical regardless of
    /// which channel drives it. (dB -75 → 0, dB -30 → 1; raw level, no AGC.)
    nonisolated static func waveformLevel(rms: Float) -> Float {
        let dB = 20 * log10(max(rms, 1e-6))
        return max(Float(0), min(Float(1), (dB + 75) / 45))
    }

    // MARK: - Cleanup

    private func cleanup() async {
        stopElapsedTimer()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        if let stream = scStream {
            try? await stream.stopCapture()
            scStream = nil
        }

        // Error path — discard any in-progress screen recording.
        screenRecorder?.cancel()
        screenRecorder = nil

        // Wait for any in-flight detached transcription to finish before
        // releasing the shared ASR engine reference and re-enabling voice
        // input. Otherwise the voice service could grab the same non-thread-safe
        // model while this task is still calling transcribe on it.
        await pendingTranscriptionTask?.value
        pendingTranscriptionTask = nil

        asrEngine?.unload()  // Meeting owns this engine — free it now
        asrEngine = nil
        vadModel = nil

        // Close the WAV handle so the empty-meeting delete can proceed.
        transcriptWriter.audioFile = nil

        // Discard empty meetings here too (cleanup path triggers when the
        // recording errored out before any segments were captured).
        if transcriptWriter.transcribedSegmentCount == 0, let path = transcriptWriter.markdownFilePath {
            try? FileManager.default.removeItem(atPath: path)
            if let audioPath = transcriptWriter.audioFilePath {
                try? FileManager.default.removeItem(atPath: audioPath)
            }
            transcriptWriter.audioFilePath = nil
            transcriptWriter.markdownFilePath = nil
        } else {
            transcriptWriter.finalizeMarkdown(startTime: startTime)
            NotificationCenter.default.post(name: .meetingFilesDidChange, object: nil)
        }
        voiceService?.setMeetingActive(false)
        processingMarkdownPath = nil
        state = .idle
    }
}

// MARK: - SCStreamOutput

extension MeetingService: @preconcurrency SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard recordingFlag.value else { return }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let length = CMBlockBufferGetDataLength(dataBuffer)
        guard length > 0 else { return }

        // Copy block buffer data into a raw buffer, then load as Float32
        let byteCount = length
        let floatCount = byteCount / MemoryLayout<Float32>.size
        guard floatCount > 0 else { return }

        let rawBuffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<Float32>.alignment)
        let copyStatus = CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: byteCount, destination: rawBuffer)
        guard copyStatus == kCMBlockBufferNoErr else {
            rawBuffer.deallocate()
            return
        }

        let floatPtr = rawBuffer.assumingMemoryBound(to: Float32.self)
        let samples = Array(UnsafeBufferPointer(start: floatPtr, count: floatCount))
        rawBuffer.deallocate()

        audioBuffer.appendSystem(samples)

        // Drive the waveform from system audio as well. The mic tap stops firing
        // when the mic is occupied by another app (mic chunks=0), so without this
        // the overlay would sit flat even while system audio records fine.
        var sumSq: Float = 0
        for s in samples { sumSq += s * s }
        let sysRMS = sqrtf(sumSq / Float(max(samples.count, 1)))
        let level = audioLevelTracker.setSystem(Self.waveformLevel(rms: sysRMS))
        DispatchQueue.main.async {
            self.overlay.updateAudioLevel(level)
        }
    }
}
