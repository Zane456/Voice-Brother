import Accelerate
import AVFoundation
import Combine
import CoreMedia
import Foundation
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

    // MARK: - Dependencies

    private let configManager: ConfigManager
    private weak var voiceService: VoiceService?
    private let summarizer: MeetingSummarizer

    // MARK: - Internal State

    private var asrEngine: (any ASREngineProtocol)?
    private var vadModel: SileroVADModel?
    private var audioEngine: AVAudioEngine?
    private var scStream: SCStream?
    private nonisolated(unsafe) let audioBuffer = AudioChunkBuffer()
    private var startTime: Date?
    private var markdownFilePath: String?
    /// Streaming-writer for the raw mixed recording (Int16 PCM WAV at 16 kHz).
    /// Written in the same loop that mixes audio for ASR, so we don't double
    /// the CPU cost of resampling. Deleted at finalize if the meeting was
    /// empty (no speech captured).
    private var audioFile: AVAudioFile?
    private var audioFilePath: String?
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
    /// Counts non-empty transcription segments written to the markdown file.
    /// Used to skip saving + summarising when a meeting captured no speech
    /// (e.g. user toggled recording then walked away from the mic).
    private var transcribedSegmentCount: Int = 0

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

        // Ensure the voice service has loaded a model (model must be cached)
        let modelString = configManager.model
        guard ASRModel(rawValue: modelString) != nil else {
            state = .error("无效的模型配置")
            return
        }

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
        state = .recording
        startTime = Date()
        elapsedSeconds = 0

        startElapsedTimer()

        // Suppress single-key voice input during meeting
        voiceService?.keyboardListenerRef?.isMeetingActive = true

        // Show recording indicator (meeting mode = red REC + timer)
        RecordingOverlayPanel.shared.show(mode: .meeting)

        recordingTask = Task { @MainActor in
            do {
                // Share the already-loaded engine from voice service (no reload needed).
                // Safe because voice recording is suppressed during meetings (meetingActive = true).
                guard let engine = self.voiceService?.asrEngineRef else {
                    self.state = .error("语音服务未加载模型")
                    self.voiceService?.keyboardListenerRef?.isMeetingActive = false
                    RecordingOverlayPanel.shared.hide()
                    return
                }
                self.asrEngine = engine

                // Load VAD model (small, loads quickly)
                let vad = try await SileroVADModel.fromPretrained(engine: .coreml)
                self.vadModel = vad

                guard !Task.isCancelled else {
                    self.asrEngine = nil  // Don't unload — shared with voice service
                    self.vadModel = nil
                    self.voiceService?.keyboardListenerRef?.isMeetingActive = false
                    return
                }

                // Initialize markdown file
                self.initMarkdown()

                // Start recording
                try await self.runRecording()

            } catch {
                self.state = .error("会议录制失败: \(error.localizedDescription)")
                await self.cleanup()
            }
        }
    }

    func stop() {
        guard state == .recording else { return }
        state = .finishing
        isRecording = false
        stopElapsedTimer()

        // Hide recording indicator
        RecordingOverlayPanel.shared.hide()

        // Keep meetingActive = true during finalization to prevent voice service
        // from accessing the shared model. It will be set to false in runRecording()
        // after finalization completes.
    }

    func toggle() {
        switch state {
        case .idle:
            start()
        case .recording:
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
        let filename = "会议纪要_\(ts).md"
        markdownFilePath = (savePath as NSString).appendingPathComponent(filename)
        transcribedSegmentCount = 0  // reset for the new meeting
        lastSegmentEndTime = nil
        currentParagraphStartTime = nil
        lastSegmentText = ""

        // Open the raw-audio WAV file alongside the markdown. Int16 LPCM at
        // 16 kHz mono — the same rate ASR works at, so we skip re-resampling.
        // ~115 MB per hour, which is acceptable for a meeting archive and far
        // smaller than keeping the Float32 mix in memory until finalize.
        let audioFilename = "会议录音_\(ts).wav"
        let audioPath = (savePath as NSString).appendingPathComponent(audioFilename)
        audioFilePath = audioPath
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
        # 会议纪要

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

        // Start microphone capture
        let micEngine = AVAudioEngine()
        let inputNode = micEngine.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        )!

        let micConverter = AVAudioConverter(from: micFormat, to: targetFormat)!

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
                let normalized = max(Float(0), min(Float(1), (dB + 50) / 40))
                DispatchQueue.main.async {
                    RecordingOverlayPanel.shared.updateAudioLevel(normalized)
                }
            }

            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / micFormat.sampleRate)
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            let status = micConverter.convert(to: converted, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
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
            writeToFile("> ⚠️ 系统音频未能采集（可能未授予屏幕录制权限），本次会议仅录制麦克风。\n\n")
        }

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

            // Mix audio
            if let mixed = mixAudio(sysChunks: currentSys, micChunks: currentMic), !mixed.isEmpty {
                accumulated.append(contentsOf: mixed)
                // Stream the same mixed samples to the WAV file. Doing it here
                // means the archive audio is always exactly what ASR heard —
                // if the user later replays the recording and something was
                // misrecognised they can hear exactly what the mic picked up.
                appendAudioSamples(mixed)
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
            NotificationCenter.default.post(name: .meetingFilesDidChange, object: nil)
        }

        // Release model references (don't unload — ASR engine is shared with voice service)
        asrEngine = nil
        vadModel = nil

        // Auto-summarize if meeting LLM is configured and enabled — but only
        // when there's actual content to summarise.
        if !isEmptyMeeting, configManager.meetingLLMEnabled,
           !configManager.meetingSummaryPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let path = markdownFilePath {
            state = .summarizing
            summaryError = nil
            do {
                try await summarizer.summarize(transcriptPath: path)
                NotificationCenter.default.post(name: .meetingFilesDidChange, object: nil)
            } catch {
                summaryError = error.localizedDescription
                print("[MeetingService] Summarization failed: \(error)")
            }
        } else if !isEmptyMeeting && configManager.meetingLLMEnabled {
            print("[MeetingService] LLM enabled but prompt is empty — skipping summarization.")
        }

        // Re-enable single-key voice input now that finalization is complete
        voiceService?.keyboardListenerRef?.isMeetingActive = false

        // Update state
        state = .idle
    }

    // MARK: - Audio Mixing (vDSP-optimized, minimal allocations)

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

        pendingTranscriptionTask = Task.detached { [weak self] in
            // Serialize: wait for previous segment to finish
            await previousTask?.value

            // Snapshot the user-selected language on the main actor before
            // hopping to the detached transcription task. nil = auto-detect.
            let languageHint: String? = await MainActor.run { [weak self] in
                self?.configManager.meetingLanguage.asrLanguageHint
            }
            let text = engine.transcribe(
                audio: capturedAudio,
                sampleRate: sampleRate,
                language: languageHint,
                context: nil
            )
            let processed = TextProcessor.collapseRepeats(
                in: TextProcessor.removeFillers(from: text)
            )
            if !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

        // Wait for any in-flight detached transcription to finish before
        // releasing the shared ASR engine reference and re-enabling voice
        // input. Otherwise the voice service could grab the same non-thread-safe
        // model while this task is still calling transcribe on it.
        await pendingTranscriptionTask?.value
        pendingTranscriptionTask = nil

        asrEngine = nil  // Don't unload — shared with voice service
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
