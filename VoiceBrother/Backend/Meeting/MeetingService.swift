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
@MainActor
final class MeetingService: NSObject, ObservableObject, MeetingServiceProtocol {

    // MARK: - Constants

    private static let sampleRate: Double = 16000
    private static let sckSampleRate: Double = 48000
    private static let vadMinAccumulate: Double = 20.0   // seconds before looking for cut points
    private static let vadSilenceThreshold: Double = 0.8 // seconds of silence to trigger cut
    private static let vadForceCut: Double = 40.0        // seconds max before force cut
    private static let vadOverlap: Double = 0.5          // seconds of overlap at boundaries
    private static let targetRMS: Float = 0.05
    private static let epsilon: Float = 1e-8

    // MARK: - Published State

    @Published var state: MeetingState = .idle
    @Published var elapsedSeconds: Int = 0
    @Published var savePath: String
    @Published var summaryError: String?
    /// Absolute path of the markdown file for the meeting currently being
    /// finalized. Non-nil only while `state` is `.finishing` / `.summarizing`;
    /// the History tab uses it to badge that file card as "生成中".
    @Published private(set) var processingMarkdownPath: String?
    /// Model load/download progress (0...1) while `state == .preparing`.
    /// nil once recording starts. Driven by `Qwen3ASRModel.fromPretrained`.
    @Published var prepareProgress: Double?

    // MARK: - Dependencies

    private let configManager: ConfigManager
    private weak var voiceService: VoiceService?
    private let summarizer: MeetingSummarizer

    // MARK: - Internal State

    private var asrEngine: (any ASREngineProtocol)?
    private var vadModel: SileroVADModel?
    private var audioEngine: AVAudioEngine?
    private var scStream: SCStream?
    /// Screen recorder for the current meeting — non-nil only while a meeting
    /// with screen recording enabled is in progress.
    private var screenRecorder: MeetingScreenRecorder?
    private nonisolated(unsafe) let audioBuffer = AudioChunkBuffer()
    private var startTime: Date?
    private var markdownFilePath: String?
    /// Streaming-writer for the raw mixed recording (Int16 PCM WAV at 16 kHz).
    /// Written in the same loop that mixes audio for ASR, so we don't double
    /// the CPU cost of resampling. Deleted at finalize if the meeting was
    /// empty (no speech captured).
    private var audioFile: AVAudioFile?
    private var audioFilePath: String?
    /// Absolute path of the screen-recording `.mov` for the current meeting.
    /// Set in `initMarkdown` alongside the markdown/WAV paths so all three
    /// share one timestamp; the recorder is only created if screen recording
    /// is enabled.
    private var videoFilePath: String?
    /// Pre-allocated format used to hand Float32 samples to AVAudioFile, which
    /// internally transcodes to Int16 LPCM for the WAV file.
    private lazy var audioWriteFormat: AVAudioFormat? =
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: Self.sampleRate,
                      channels: 1,
                      interleaved: false)
    private var elapsedTimer: Timer?
    private var recordingTask: Task<Void, Never>?
    private var pendingTranscriptionTask: Task<Void, Never>?
    /// Watchdog that force-fails a meeting stranded in `.preparing` by a hung
    /// model load (e.g. a HuggingFace snapshot that never returns).
    private var loadWatchdog: Task<Void, Never>?
    /// Bumped on every `start()` and on every `.preparing`-state stop. The
    /// startup task checks it before mutating shared state, so a model load
    /// that hangs and only returns much later cannot clobber a meeting the
    /// user has since cancelled or restarted.
    private var startGeneration = 0
    /// Counts non-empty transcription segments written to the markdown file.
    /// Used to skip saving + summarising when a meeting captured no speech
    /// (e.g. user toggled recording then walked away from the mic).
    private var transcribedSegmentCount: Int = 0

    /// UUID identifying the current meeting, used as the `session` field in
    /// `ASRLogger` events. Refreshed on each `start()`; never cleared so late
    /// events (segment_transcribed after .idle) still trace back.
    private var currentSessionID: UUID?

    // MARK: - Soft-merge state for appendSegment
    //
    // Rather than emit one timestamped line per VAD segment (which produces
    // hundreds of one-line bullets in a typical 1h meeting), we soft-merge
    // segments that arrive close together into a single markdown paragraph.
    // The state below tracks where the current paragraph started and what was
    // last written, which is also used to drop consecutive duplicate phrases
    // that the ASR sometimes emits across adjacent segments.

    /// Wall-clock time of the most recently written segment. nil before the
    /// first segment of a meeting; reset in `initMarkdown()`.
    private var lastSegmentEndTime: Date?
    /// Wall-clock time of the *first* segment in the current paragraph. Used
    /// to force a new paragraph after `paragraphMaxDuration` seconds even
    /// when the speaker barely pauses.
    private var currentParagraphStartTime: Date?
    /// Text of the most recently written segment, used for consecutive-
    /// duplicate suppression. Stored after trimming.
    private var lastSegmentText: String = ""

    /// A gap of this many seconds between two segments forces a new paragraph.
    /// Tuned for typical meeting cadence — most genuine topic shifts include
    /// at least this much silence; sub-30s gaps usually mean the same speaker
    /// is continuing the same thought.
    private static let paragraphSilenceGap: TimeInterval = 30
    /// Force a new paragraph after this much continuous content even without
    /// a long silence, so we don't end up with a single 30-minute paragraph
    /// during a monologue.
    private static let paragraphMaxDuration: TimeInterval = 180

    /// Nonisolated recording flag for thread-safe access from SCStreamOutput callback.
    private nonisolated(unsafe) let recordingFlag = ThreadSafeFlag()

    /// Thread-safe getter for isRecording.
    private var isRecording: Bool {
        get { recordingFlag.value }
        set { recordingFlag.value = newValue }
    }

    // MARK: - Init

    init(configManager: ConfigManager, voiceService: VoiceService) {
        self.configManager = configManager
        self.voiceService = voiceService
        self.savePath = configManager.meetingSavePath
        self.summarizer = MeetingSummarizer(configManager: configManager)
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
        RecordingOverlayPanel.shared.show(mode: .meeting, preparing: true)

        // New meeting attempt — bump the generation token. The startup task
        // and the watchdog both capture `gen` and check it before mutating
        // shared state, so a hung load that returns late can't clobber a
        // meeting the user has since cancelled or restarted.
        startGeneration &+= 1
        let gen = startGeneration

        // Suppress single-key voice input for the whole meeting lifecycle —
        // avoids microphone contention and prevents a second ASR model from
        // being loaded while the meeting's own model is resident.
        voiceService?.keyboardListenerRef?.isMeetingActive = true
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
                    self.voiceService?.keyboardListenerRef?.isMeetingActive = false
                    self.prepareProgress = nil
                    RecordingOverlayPanel.shared.hide()
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
                RecordingOverlayPanel.shared.beginRecording()

                // Initialize markdown file
                self.initMarkdown()

                // Start recording
                try await self.runRecording()

            } catch {
                // If the watchdog / a stop() already recovered this meeting,
                // don't touch state — the error belongs to a disowned task.
                guard self.startGeneration == gen else {
                    DebugLog.error("[MeetingService] orphaned startup task error: \(error)")
                    return
                }
                self.loadWatchdog?.cancel()
                self.loadWatchdog = nil
                RecordingOverlayPanel.shared.hide()
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
            voiceService?.keyboardListenerRef?.isMeetingActive = false
            prepareProgress = nil
            RecordingOverlayPanel.shared.hide()
            state = .idle
        case .recording:
            ASRLogger.shared.event(.meetingFinishing, sessionID: currentSessionID, scope: .meeting,
                                   props: ["segments": transcribedSegmentCount,
                                           "elapsed_s": elapsedSeconds])
            state = .finishing
            // Expose the in-progress markdown file so the History tab can
            // badge it as "生成中" until finalization + summarization finish.
            processingMarkdownPath = markdownFilePath
            isRecording = false
            stopElapsedTimer()

            // Hide recording indicator
            RecordingOverlayPanel.shared.hide()

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
                RecordingOverlayPanel.shared.updateMeetingElapsed(self.elapsedSeconds)
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // MARK: - Markdown File Management

    private func initMarkdown() {
        guard let start = startTime else { return }

        do {
            try FileManager.default.createDirectory(atPath: savePath, withIntermediateDirectories: true)
        } catch {
            print("[MeetingService] Failed to create save directory: \(error)")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let ts = formatter.string(from: start)
        let filename = "声音录制_\(ts).md"
        markdownFilePath = (savePath as NSString).appendingPathComponent(filename)
        transcribedSegmentCount = 0  // reset for the new meeting
        lastSegmentEndTime = nil
        currentParagraphStartTime = nil
        lastSegmentText = ""

        // Open the raw-audio WAV file alongside the markdown. Int16 LPCM at
        // 16 kHz mono — the same rate ASR works at, so we skip re-resampling.
        // ~115 MB per hour, which is acceptable for a meeting archive and far
        // smaller than keeping the Float32 mix in memory until finalize.
        let audioFilename = "录音_\(ts).wav"
        let audioPath = (savePath as NSString).appendingPathComponent(audioFilename)
        audioFilePath = audioPath

        // Screen recording (if enabled) writes a .mov alongside, sharing the
        // same timestamp so the meeting's files group together.
        let videoFilename = "录屏_\(ts).mov"
        videoFilePath = (savePath as NSString).appendingPathComponent(videoFilename)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            audioFile = try AVAudioFile(
                forWriting: URL(fileURLWithPath: audioPath),
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            print("[MeetingService] Failed to open audio WAV for writing: \(error)")
            audioFile = nil
            audioFilePath = nil
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFormatter.string(from: start)

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let timeStr = timeFormatter.string(from: start)

        let header = """
        # 声音录制

        - 日期：\(dateStr)
        - 时间：\(timeStr) -
        - 时长：

        ---

        """
        writeToFile(header)
    }

    private func finalizeMarkdown() {
        guard let path = markdownFilePath,
              let start = startTime,
              FileManager.default.fileExists(atPath: path) else { return }

        let end = Date()
        let duration = Int(end.timeIntervalSince(start))
        let hours = duration / 3600
        let minutes = (duration % 3600) / 60
        let seconds = duration % 60

        let durStr: String
        if hours > 0 {
            durStr = "\(hours)小时\(minutes)分钟"
        } else {
            durStr = "\(minutes)分钟\(seconds)秒"
        }

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let startTimeStr = timeFormatter.string(from: start)
        let endTimeStr = timeFormatter.string(from: end)

        do {
            var content = try String(contentsOfFile: path, encoding: .utf8)
            content = content.replacingOccurrences(
                of: "- 时间：\(startTimeStr) - \n",
                with: "- 时间：\(startTimeStr) - \(endTimeStr)\n"
            )
            content = content.replacingOccurrences(
                of: "- 时长：\n",
                with: "- 时长：\(durStr)\n"
            )
            // The soft-merge writer omits the trailing "\n\n" at the end of
            // the last paragraph (it's only emitted as a separator before the
            // *next* paragraph). Add a final newline here so the file ends
            // cleanly the way every markdown viewer expects.
            if !content.hasSuffix("\n") {
                content += "\n"
            }
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            print("[MeetingService] Failed to finalize markdown: \(error)")
        }
    }

    /// Append a transcribed segment to the markdown file with three layers
    /// of post-filtering tuned to make the output actually readable:
    ///
    /// 1. **Minimum content threshold.** A segment must contribute at least
    ///    3 non-punctuation, non-whitespace characters. Drops single-token
    ///    noise like "OK。", "哦。", "嗯。", which are the dominant source of
    ///    visual clutter in long meetings.
    /// 2. **Consecutive-duplicate suppression.** Qwen3-ASR sometimes emits
    ///    the exact same short phrase across adjacent VAD segments (especially
    ///    around silences). We drop the second copy.
    /// 3. **Soft paragraph merging.** Segments arriving within
    ///    `paragraphSilenceGap` seconds of the previous one are appended to
    ///    the same paragraph (no new timestamp), turning hundreds of one-line
    ///    entries into a few dozen readable paragraphs. A new paragraph is
    ///    started either after a long silence gap or after
    ///    `paragraphMaxDuration` seconds of continuous content.
    ///
    /// File-format invariant: each paragraph begins with `**[HH:mm:ss]** `.
    /// Trailing blank lines between paragraphs are written *before* the next
    /// paragraph begins, so the file stays well-formed even if the meeting
    /// ends mid-paragraph (`finalizeMarkdown` then ensures a trailing newline).
    private func appendSegment(timestamp: Date, text: String) {
        guard markdownFilePath != nil else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop empty / nearly-empty segments — punctuation-only or single-
        // character utterances rarely carry information in a transcript and
        // cost a lot of vertical space.
        let meaningful = trimmed.unicodeScalars.filter { scalar in
            !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        guard meaningful.count >= 3 else { return }

        // Drop consecutive duplicates from ASR re-emitting the same phrase.
        guard trimmed != lastSegmentText else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let tsStr = formatter.string(from: timestamp)

        // Decide: same paragraph or new paragraph?
        let isNewParagraph: Bool = {
            guard let lastEnd = lastSegmentEndTime,
                  let pStart = currentParagraphStartTime else { return true }
            if timestamp.timeIntervalSince(lastEnd) >= Self.paragraphSilenceGap {
                return true
            }
            if timestamp.timeIntervalSince(pStart) >= Self.paragraphMaxDuration {
                return true
            }
            return false
        }()

        if isNewParagraph {
            // Close the previous paragraph (if any) with a blank-line separator,
            // then start a new timestamped one.
            let prefix = (lastSegmentEndTime == nil) ? "" : "\n\n"
            writeToFile("\(prefix)**[\(tsStr)]** \(trimmed)")
            currentParagraphStartTime = timestamp
        } else {
            // Append inline to the current paragraph. A leading space keeps
            // sentences from running together when the previous one didn't
            // end in punctuation.
            writeToFile(" \(trimmed)")
        }

        lastSegmentText = trimmed
        lastSegmentEndTime = timestamp
        transcribedSegmentCount += 1
    }

    /// Append a mono Float32 sample buffer to the currently-open WAV file.
    /// Silently no-ops if the file failed to open at meeting start — we never
    /// want audio-file trouble to kill the ASR path that's the user's
    /// primary experience.
    private func appendAudioSamples(_ samples: [Float]) {
        guard let audioFile = audioFile,
              let format = audioWriteFormat,
              !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }
        }
        do {
            try audioFile.write(from: buffer)
        } catch {
            print("[MeetingService] Audio WAV write failed: \(error) — dropping future samples")
            self.audioFile = nil
        }
    }

    private func writeToFile(_ content: String) {
        guard let path = markdownFilePath else { return }
        guard let data = content.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: path) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - Recording Loop

    private func runRecording() async throws {
        isRecording = true
        audioBuffer.clearAll()

        // Start microphone capture.
        let micEngine = AVAudioEngine()
        let inputNode = micEngine.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        )!

        // 某些场景（如微信通话）系统会把输入切到 VPIO 多通道模式，这种格式无标准
        // channel layout，AVAudioConverter 无法降混（会输出全 0）。转换器只做采样率
        // 转换，降混在 tap 里手动取 ch0。麦克风增益由下游 mixAudio 的 RMS 归一化处理。
        let micMonoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: micFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!
        let micConverter = AVAudioConverter(from: micMonoFormat, to: targetFormat)!

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }

            // Compute RMS audio level for waveform animation
            if let rawChannel = buffer.floatChannelData?[0] {
                let frameLength = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frameLength {
                    sum += rawChannel[i] * rawChannel[i]
                }
                let rms = sqrtf(sum / Float(max(frameLength, 1)))
                let dB = 20 * log10(max(rms, 1e-6))
                // Same window as VoiceService — raw mic level without VPIO/AGC.
                let normalized = max(Float(0), min(Float(1), (dB + 75) / 45))
                DispatchQueue.main.async {
                    RecordingOverlayPanel.shared.updateAudioLevel(normalized)
                }
            }

            // VP 给的是多通道 buffer（各通道内容相同），手动取 ch0 拼成单声道，
            // 再交给转换器做采样率转换。
            guard buffer.frameLength > 0, let srcChannel = buffer.floatChannelData?[0] else { return }
            guard let monoBuffer = AVAudioPCMBuffer(
                pcmFormat: micMonoFormat,
                frameCapacity: buffer.frameLength
            ) else { return }
            monoBuffer.frameLength = buffer.frameLength
            memcpy(monoBuffer.floatChannelData![0], srcChannel,
                   Int(buffer.frameLength) * MemoryLayout<Float>.size)

            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / micFormat.sampleRate)
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            let status = micConverter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return monoBuffer
            }
            guard status != .error else { return }

            if let channelData = converted.floatChannelData {
                let samples = Array(UnsafeBufferPointer(
                    start: channelData[0],
                    count: Int(converted.frameLength)
                ))
                self.audioBuffer.appendMic(samples)
            }
        }

        self.audioEngine = micEngine
        try micEngine.start()
        DebugLog.write("[MeetingService] Mic engine started: outputFormat=\(micFormat.sampleRate)Hz/\(micFormat.channelCount)ch, inputFormat=\(inputNode.inputFormat(forBus: 0).sampleRate)Hz/\(inputNode.inputFormat(forBus: 0).channelCount)ch, voiceProcessing=\(inputNode.isVoiceProcessingEnabled)")

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
                let quality = configManager.meetingVideoQuality
                // Capture at the display's native pixel resolution (not its
                // point size) so Retina screens aren't softened before the
                // quality tier even applies its height cap.
                let mode = CGDisplayCopyDisplayMode(display.displayID)
                let nativeW = mode?.pixelWidth ?? display.width
                let nativeH = mode?.pixelHeight ?? display.height
                let videoSize = Self.screenRecordingSize(
                    pixelWidth: nativeW,
                    pixelHeight: nativeH,
                    quality: quality
                )
                config.width = Int(videoSize.width)
                config.height = Int(videoSize.height)
                config.minimumFrameInterval = CMTime(value: 1, timescale: 24)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                let recorder = MeetingScreenRecorder(outputURL: URL(fileURLWithPath: videoPath))
                recorder.start(displaySize: videoSize, bitrate: quality.bitrate)
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
                writeToFile("> ⚠️ 系统音频与屏幕录制未能启用（可能未授予屏幕录制权限），本次录制仅采集麦克风。\n\n")
            } else {
                writeToFile("> ⚠️ 系统音频未能采集（可能未授予屏幕录制权限），本次录制仅采集麦克风。\n\n")
            }
        }
        DebugLog.write("[MeetingService] System audio capture started=\(systemAudioCaptured), screenRecording=\(screenRecordingEnabled)")

        // Main recording loop
        // Pre-allocate for vadForceCut duration to avoid repeated resizing
        let reserveCapacity = Int(Self.vadForceCut * Self.sampleRate)
        var accumulated: [Float] = []
        accumulated.reserveCapacity(reserveCapacity)
        var segmentStartTime = Date()

        while isRecording {
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 second (reduced from 1s)

            // Collect buffered audio
            let (currentMic, currentSys) = audioBuffer.swapAll()

            // Diagnostic: per-window capture levels — reveals whether the mic
            // or the system-audio path is silent. Remove once the capture
            // problem is diagnosed and fixed.
            let micSamples = currentMic.reduce(0) { $0 + $1.count }
            let sysSamples = currentSys.reduce(0) { $0 + $1.count }
            let micRMS = Self.rmsOfChunks(currentMic)
            let sysRMS = Self.rmsOfChunks(currentSys)
            DebugLog.write("[MeetingService] window mic[chunks=\(currentMic.count) samples=\(micSamples) RMS=\(String(format: "%.5f", micRMS))] sys[chunks=\(currentSys.count) samples=\(sysSamples) RMS=\(String(format: "%.5f", sysRMS))]")

            // Mix audio
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

            let duration = Double(accumulated.count) / Self.sampleRate

            if duration >= Self.vadMinAccumulate {
                let cutPoint = findCutPoint(in: accumulated)

                if cutPoint != nil || duration >= Self.vadForceCut {
                    let rawCut = cutPoint ?? accumulated.count
                    let actualCut = max(0, min(rawCut, accumulated.count))
                    let overlapSamples = Int(Self.vadOverlap * Self.sampleRate)
                    let segment = Array(accumulated.prefix(actualCut))

                    // Use removeFirst instead of dropFirst+Array to avoid creating a second full copy
                    let removeCount = max(0, min(actualCut - overlapSamples, accumulated.count))
                    accumulated.removeFirst(removeCount)

                    // Transcribe segment
                    transcribeSegment(segment, timestamp: segmentStartTime)
                    segmentStartTime = Date()
                }
            }
        }

        // Process remaining audio
        if accumulated.count > Int(Self.sampleRate) {
            transcribeSegment(accumulated, timestamp: segmentStartTime)
        }
        accumulated = [] // Release memory immediately

        // Wait for any in-flight transcription to complete
        await pendingTranscriptionTask?.value
        pendingTranscriptionTask = nil

        // Stop captures
        inputNode.removeTap(onBus: 0)
        micEngine.stop()
        self.audioEngine = nil

        if let stream = scStream {
            try? await stream.stopCapture()
            self.scStream = nil
        }

        // Skip persisting the meeting at all if no speech was captured —
        // user toggled record then walked away from the mic, no point
        // saving an empty header-only markdown or running the summary LLM.
        let isEmptyMeeting = transcribedSegmentCount == 0

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

        // Close the audio file before touching the filesystem — releases the
        // handle so we can delete it cleanly if the meeting was empty.
        audioFile = nil

        if isEmptyMeeting, let path = markdownFilePath {
            try? FileManager.default.removeItem(atPath: path)
            if let audioPath = audioFilePath {
                try? FileManager.default.removeItem(atPath: audioPath)
            }
            audioFilePath = nil
            print("[MeetingService] Discarded empty meeting (no transcribed segments).")
            markdownFilePath = nil
        } else {
            finalizeMarkdown()
            // A meeting with content just completed — History tab opens on
            // the meeting segment next.
            configManager.lastHistoryKind = "meeting"
            NotificationCenter.default.post(name: .meetingFilesDidChange, object: nil)
        }

        // Unload the meeting's own ASR model — meetings own this instance
        // (it is not shared with voice input) and free it between meetings so
        // it occupies no memory while idle.
        asrEngine?.unload()
        asrEngine = nil
        vadModel = nil

        // Recording + file finalization are done. Re-enable voice input and
        // return to .idle NOW so the user can start the next meeting the
        // instant they want — LLM summarization is a slow network call and
        // must not sit on the critical path between meetings (a double-Command
        // during summarization used to be silently swallowed).
        voiceService?.keyboardListenerRef?.isMeetingActive = false
        state = .idle

        // Auto-summarize in a detached background task. `processingMarkdownPath`
        // stays set so the History tab keeps the "生成中" badge on this file
        // until the summary lands; the detached task clears it when done —
        // but only if a newer meeting hasn't since claimed the badge.
        if !isEmptyMeeting, configManager.meetingLLMEnabled,
           let path = markdownFilePath {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.summaryError = nil
                do {
                    try await self.summarizer.summarize(transcriptPath: path)
                    NotificationCenter.default.post(name: .meetingFilesDidChange, object: nil)
                } catch {
                    self.summaryError = error.localizedDescription
                    print("[MeetingService] Summarization failed: \(error)")
                }
                if self.processingMarkdownPath == path {
                    self.processingMarkdownPath = nil
                }
            }
        } else {
            processingMarkdownPath = nil
        }
    }

    // MARK: - Audio Mixing (vDSP-optimized, minimal allocations)

    /// Diagnostic helper: RMS across a list of audio chunks. Returns 0 when empty.
    static func rmsOfChunks(_ chunks: [[Float]]) -> Float {
        var sum: Float = 0
        var count = 0
        for chunk in chunks {
            for s in chunk { sum += s * s }
            count += chunk.count
        }
        return count > 0 ? (sum / Float(count)).squareRoot() : 0
    }

    private func mixAudio(sysChunks: [[Float]], micChunks: [[Float]]) -> [Float]? {
        // Concatenate chunks into contiguous arrays
        let sysTotal = sysChunks.reduce(0) { $0 + $1.count }
        let micTotal = micChunks.reduce(0) { $0 + $1.count }

        if sysTotal == 0 && micTotal == 0 { return nil }

        // Resample system audio from 48kHz to 16kHz in-place
        var sysAudio: [Float]
        if sysTotal > 0 {
            var rawSys = [Float]()
            rawSys.reserveCapacity(sysTotal)
            for chunk in sysChunks { rawSys.append(contentsOf: chunk) }
            sysAudio = resample(rawSys, from: Self.sckSampleRate, to: Self.sampleRate)
        } else {
            sysAudio = []
        }

        var micAudio: [Float]
        if micTotal > 0 {
            micAudio = [Float]()
            micAudio.reserveCapacity(micTotal)
            for chunk in micChunks { micAudio.append(contentsOf: chunk) }
        } else {
            micAudio = []
        }

        let maxLen = max(sysAudio.count, micAudio.count)
        if maxLen == 0 { return nil }

        // Zero-pad to same length
        if sysAudio.count < maxLen {
            sysAudio.append(contentsOf: repeatElement(Float(0), count: maxLen - sysAudio.count))
        }
        if micAudio.count < maxLen {
            micAudio.append(contentsOf: repeatElement(Float(0), count: maxLen - micAudio.count))
        }

        // RMS normalization + 50/50 mix using vDSP (single output array, no extra copies)
        var sysRMS: Float = 0
        vDSP_rmsqv(sysAudio, 1, &sysRMS, vDSP_Length(maxLen))
        let sysScale = Self.targetRMS / (sysRMS + Self.epsilon) * 0.5

        var micRMS: Float = 0
        vDSP_rmsqv(micAudio, 1, &micRMS, vDSP_Length(maxLen))
        let micScale = Self.targetRMS / (micRMS + Self.epsilon) * 0.5

        // sysAudio *= sysScale (in-place)
        var sysScaleVar = sysScale
        vDSP_vsmul(sysAudio, 1, &sysScaleVar, &sysAudio, 1, vDSP_Length(maxLen))

        // sysAudio += micAudio * micScale (in-place, reuse sysAudio as output)
        var micScaleVar = micScale
        vDSP_vsma(micAudio, 1, &micScaleVar, sysAudio, 1, &sysAudio, 1, vDSP_Length(maxLen))

        return sysAudio
    }

    /// Linear interpolation resampling using vDSP.
    private func resample(_ input: [Float], from inputRate: Double, to outputRate: Double) -> [Float] {
        guard inputRate != outputRate, !input.isEmpty else { return input }
        let ratio = inputRate / outputRate
        let outputCount = Int(Double(input.count) / ratio)
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        // vDSP_vlint performs vectorized linear interpolation
        var control = [Float](unsafeUninitializedCapacity: outputCount) { buffer, count in
            for i in 0..<outputCount {
                buffer[i] = Float(Double(i) * ratio)
            }
            count = outputCount
        }
        vDSP_vlint(input, &control, 1, &output, 1, vDSP_Length(outputCount), vDSP_Length(input.count))
        return output
    }

    // MARK: - Screen Recording

    /// Pixel size for the screen-recording video: the display's native pixel
    /// aspect ratio, with height capped per the chosen quality tier (a `nil`
    /// cap means native resolution). Both dimensions are rounded to even
    /// numbers (H.264 requires even width/height).
    private static func screenRecordingSize(pixelWidth: Int, pixelHeight: Int,
                                            quality: MeetingVideoQuality) -> CGSize {
        guard pixelWidth > 0, pixelHeight > 0 else {
            return CGSize(width: 1920, height: 1080)
        }
        let aspect = Double(pixelWidth) / Double(pixelHeight)
        var h = pixelHeight
        if let cap = quality.maxHeight { h = min(h, cap) }
        var w = Int((Double(h) * aspect).rounded())
        if w % 2 != 0 { w += 1 }
        if h % 2 != 0 { h += 1 }
        return CGSize(width: w, height: h)
    }

    // MARK: - VAD Segmentation

    private func findCutPoint(in audio: [Float]) -> Int? {
        guard let vad = vadModel else { return nil }

        let sampleRateInt = Int(Self.sampleRate)
        let segments = vad.detectSpeech(audio: audio, sampleRate: sampleRateInt)

        if segments.isEmpty {
            return audio.count
        }

        let sampleRateFloat = Float(Self.sampleRate)
        let silenceSamples = Int(Float(Self.vadSilenceThreshold) * sampleRateFloat)
        let audioCount = audio.count

        for i in 0..<(segments.count - 1) {
            // Clamp to valid sample range — VAD timestamps can occasionally exceed
            // the audio length, and an out-of-range cut would crash removeFirst().
            let rawGapStart = Int(segments[i].endTime * sampleRateFloat)
            let rawGapEnd = Int(segments[i + 1].startTime * sampleRateFloat)
            let gapStart = max(0, min(rawGapStart, audioCount))
            let gapEnd = max(gapStart, min(rawGapEnd, audioCount))
            if (gapEnd - gapStart) >= silenceSamples {
                return min((gapStart + gapEnd) / 2, audioCount)
            }
        }

        return nil
    }

    // MARK: - Transcription

    private func transcribeSegment(_ audio: [Float], timestamp: Date) {
        guard let engine = asrEngine else {
            appendSegment(timestamp: timestamp, text: "[转写失败：模型未加载]")
            return
        }

        // Compact long internal silences before sending to ASR. Long pauses
        // inside a chunk cause Qwen3-ASR to fall into token-loop sampling
        // (e.g. "はい。はい。はい…" or "我我我…"). VAD picks the speech
        // regions and we concatenate them with a short pad — the model sees
        // continuous speech, output stays clean.
        let compacted = compactSilences(in: audio, vad: vadModel)

        // Wait for previous transcription to finish before starting a new one,
        // preventing unbounded task accumulation and memory pressure.
        let previousTask = pendingTranscriptionTask
        let capturedAudio = compacted
        let sampleRate = Int(Self.sampleRate)

        let sessionID = currentSessionID
        ASRLogger.shared.event(.meetingSegmentStarted, sessionID: sessionID, scope: .meeting,
                               props: ["samples": compacted.count,
                                       "dur_s": Double(compacted.count) / Double(Self.sampleRate)])

        pendingTranscriptionTask = Task.detached { [weak self] in
            // Serialize: wait for previous segment to finish
            await previousTask?.value

            // Snapshot main-actor config before hopping to the detached
            // transcription task. languageHint nil = auto-detect.
            // 语气词过滤 is a shared toggle (通用 tab) — meeting honors it too.
            let (languageHint, removeFillers): (String?, Bool) = await MainActor.run { [weak self] in
                (self?.configManager.meetingLanguage.asrLanguageHint,
                 self?.configManager.removeFillers ?? true)
            }
            let segStart = Date()
            let text = engine.transcribe(
                audio: capturedAudio,
                sampleRate: sampleRate,
                language: languageHint,
                context: nil
            )
            // Drop MLX intermediates after each segment — segment durations
            // vary up to vadForceCut (40s), so without this the cache grows
            // monotonically across a long meeting.
            MLXMemoryGovernor.reclaim()
            let cleaned = removeFillers ? TextProcessor.removeFillers(from: text) : text
            let processed = TextProcessor.collapseRepeats(in: cleaned)
            let nonEmpty = !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ASRLogger.shared.event(.meetingSegmentTranscribed, sessionID: sessionID, scope: .meeting,
                                   props: ["dur_ms": ASRLogger.durMs(since: segStart),
                                           "raw_len": text.count,
                                           "out_len": processed.count,
                                           "kept": nonEmpty])
            if nonEmpty {
                await self?.appendSegment(timestamp: timestamp, text: processed)
            }
        }
    }

    /// Concatenate the speech regions detected by VAD with a short silence pad
    /// between them, dropping any long internal silence. If VAD is unavailable
    /// or finds no speech, returns the input unchanged so we never lose audio.
    private func compactSilences(in audio: [Float], vad: SileroVADModel?) -> [Float] {
        guard let vad else { return audio }
        let sr = Int(Self.sampleRate)
        let segments = vad.detectSpeech(audio: audio, sampleRate: sr)
        guard !segments.isEmpty else { return audio }

        // Total speech duration. If silences make up < 30% of the chunk
        // there's nothing meaningful to compact and we skip the copy.
        let speechDuration = segments.reduce(0.0) { $0 + Double($1.endTime - $1.startTime) }
        let totalDuration = Double(audio.count) / Double(sr)
        if speechDuration / totalDuration > 0.7 { return audio }

        let padSamples = Int(0.2 * Double(sr))
        let pad = [Float](repeating: 0, count: padSamples)
        let leadIn = Int(0.1 * Double(sr)) // small lead-in keeps onsets natural

        var out: [Float] = []
        out.reserveCapacity(Int(speechDuration * Double(sr)) + padSamples * segments.count)
        for (i, seg) in segments.enumerated() {
            let startIdx = max(0, Int(Double(seg.startTime) * Double(sr)) - leadIn)
            let endIdx = min(audio.count, Int(Double(seg.endTime) * Double(sr)) + leadIn)
            if endIdx > startIdx {
                out.append(contentsOf: audio[startIdx..<endIdx])
            }
            if i < segments.count - 1 {
                out.append(contentsOf: pad)
            }
        }
        return out.isEmpty ? audio : out
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
        audioFile = nil

        // Discard empty meetings here too (cleanup path triggers when the
        // recording errored out before any segments were captured).
        if transcribedSegmentCount == 0, let path = markdownFilePath {
            try? FileManager.default.removeItem(atPath: path)
            if let audioPath = audioFilePath {
                try? FileManager.default.removeItem(atPath: audioPath)
            }
            audioFilePath = nil
            markdownFilePath = nil
        } else {
            finalizeMarkdown()
            NotificationCenter.default.post(name: .meetingFilesDidChange, object: nil)
        }
        voiceService?.keyboardListenerRef?.isMeetingActive = false
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
    }
}

// MARK: - ThreadSafeFlag

/// A simple thread-safe boolean flag using an NSLock.
/// Used to share recording state between @MainActor and nonisolated callbacks.
final class ThreadSafeFlag: @unchecked Sendable {
    private var _value = false
    private let lock = NSLock()

    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

// MARK: - AudioChunkBuffer

/// Thread-safe audio chunk buffer shared between @MainActor and nonisolated audio callbacks.
final class AudioChunkBuffer: @unchecked Sendable {
    private var _micChunks: [[Float]] = []
    private var _sysChunks: [[Float]] = []
    private let _lock = NSLock()

    /// Max chunks before dropping oldest. At 48kHz/4096-sample buffers ≈ 12 chunks/sec,
    /// 30 chunks ≈ 2.5 seconds — well above the 0.5s swap interval.
    private let maxChunks = 30

    var systemChunks: [[Float]] {
        get { _lock.withLock { _sysChunks } }
        set { _lock.withLock { _sysChunks = newValue } }
    }

    func appendMic(_ chunk: [Float]) {
        _lock.lock()
        _micChunks.append(chunk)
        if _micChunks.count > maxChunks {
            _micChunks.removeFirst(_micChunks.count - maxChunks)
        }
        _lock.unlock()
    }

    func appendSystem(_ chunk: [Float]) {
        _lock.lock()
        _sysChunks.append(chunk)
        if _sysChunks.count > maxChunks {
            _sysChunks.removeFirst(_sysChunks.count - maxChunks)
        }
        _lock.unlock()
    }

    func clearAll() {
        _lock.lock()
        _micChunks = []
        _sysChunks = []
        _lock.unlock()
    }

    func clearSystem() {
        _lock.lock()
        _sysChunks = []
        _lock.unlock()
    }

    /// Swap and return both mic and system chunks atomically.
    func swapAll() -> (mic: [[Float]], sys: [[Float]]) {
        _lock.lock()
        defer { _lock.unlock() }
        let mic = _micChunks
        let sys = _sysChunks
        _micChunks = []
        _sysChunks = []
        return (mic, sys)
    }
}
