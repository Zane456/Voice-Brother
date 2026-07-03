import Accelerate
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import SpeechVAD

/// Owns the meeting capture + segmentation loop: mic engine, ScreenCaptureKit
/// system-audio/screen stream, mixing, resampling and VAD cut-point detection.
/// Split out of `MeetingService` (phase B).
///
/// The facade owns the meeting lifecycle (@Published state, `asrEngine`/`vadModel`,
/// `audioEngine`/`scStream`/`screenRecorder`, `pendingTranscriptionTask`); this
/// loop drives them through the weak `service` back-reference so `runRecording`
/// is a line-for-line move of the original with `self.` → `service.`. The
/// SCStreamOutput conformance stays on the facade, so the audio stream output is
/// still registered against `service`.
@MainActor
final class MeetingRecordingLoop {

    private let audioBuffer: AudioChunkBuffer
    private let recordingFlag: ThreadSafeFlag
    private let audioLevelTracker: AudioLevelTracker
    private let writer: MeetingTranscriptWriter
    private let transcriber: MeetingSegmentTranscriber
    private let configManager: ConfigManager
    weak var service: MeetingService?

    init(audioBuffer: AudioChunkBuffer,
         recordingFlag: ThreadSafeFlag,
         audioLevelTracker: AudioLevelTracker,
         writer: MeetingTranscriptWriter,
         transcriber: MeetingSegmentTranscriber,
         configManager: ConfigManager) {
        self.audioBuffer = audioBuffer
        self.recordingFlag = recordingFlag
        self.audioLevelTracker = audioLevelTracker
        self.writer = writer
        self.transcriber = transcriber
        self.configManager = configManager
    }

    /// Thread-safe getter for isRecording (shares the facade's flag instance).
    private var isRecording: Bool {
        get { recordingFlag.value }
        set { recordingFlag.value = newValue }
    }

    // MARK: - Recording Loop

    func runRecording() async throws {
        guard let service = service else { return }
        isRecording = true
        audioBuffer.clearAll()

        // Start microphone capture.
        let micEngine = AVAudioEngine()
        let inputNode = micEngine.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: MeetingService.sampleRate,
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
                // Same window as VoiceService — raw mic level without VPIO/AGC.
                let level = self.audioLevelTracker.setMic(MeetingService.waveformLevel(rms: rms))
                DispatchQueue.main.async {
                    self.service?.overlay.updateAudioLevel(level)
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

            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * MeetingService.sampleRate / micFormat.sampleRate)
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

        service.audioEngine = micEngine
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
            config.sampleRate = Int(MeetingService.sckSampleRate)
            config.channelCount = 1

            // Screen recording: configure the same stream to also emit video,
            // downscaled to ≤1080p at 10fps to keep the .mov archive small.
            if screenRecordingEnabled, let videoPath = writer.videoFilePath {
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
                service.screenRecorder = recorder
            }

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(service, type: .audio, sampleHandlerQueue: DispatchQueue(label: "sysaudio"))
            if let recorder = service.screenRecorder {
                try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.outputQueue)
            }
            try await stream.startCapture()
            service.scStream = stream
            systemAudioCaptured = true
        } catch {
            NSLog("%@", "[MeetingService] System audio capture failed: \(error). Continuing with microphone only.")
            // The stream never started — discard the recorder so its empty
            // .mov file doesn't linger.
            service.screenRecorder?.cancel()
            service.screenRecorder = nil
        }

        if !systemAudioCaptured {
            if screenRecordingEnabled {
                writer.writeToFile("> ⚠️ 系统音频与屏幕录制未能启用（可能未授予屏幕录制权限），本次录制仅采集麦克风。\n\n")
            } else {
                writer.writeToFile("> ⚠️ 系统音频未能采集（可能未授予屏幕录制权限），本次录制仅采集麦克风。\n\n")
            }
        }
        DebugLog.write("[MeetingService] System audio capture started=\(systemAudioCaptured), screenRecording=\(screenRecordingEnabled)")

        // Main recording loop
        // Pre-allocate for vadForceCut duration to avoid repeated resizing
        let reserveCapacity = Int(MeetingService.vadForceCut * MeetingService.sampleRate)
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
                writer.appendAudioSamples(mixed)
                // The screen recording reuses this exact mix as its audio track.
                service.screenRecorder?.appendAudio(mixed)
            }

            let duration = Double(accumulated.count) / MeetingService.sampleRate

            if duration >= MeetingService.vadMinAccumulate {
                let cutPoint = findCutPoint(in: accumulated)

                if cutPoint != nil || duration >= MeetingService.vadForceCut {
                    let rawCut = cutPoint ?? accumulated.count
                    let actualCut = max(0, min(rawCut, accumulated.count))
                    let overlapSamples = Int(MeetingService.vadOverlap * MeetingService.sampleRate)
                    let segment = Array(accumulated.prefix(actualCut))

                    // Use removeFirst instead of dropFirst+Array to avoid creating a second full copy
                    let removeCount = max(0, min(actualCut - overlapSamples, accumulated.count))
                    accumulated.removeFirst(removeCount)

                    // Transcribe segment
                    transcriber.transcribeSegment(segment, timestamp: segmentStartTime)
                    segmentStartTime = Date()
                }
            }
        }

        // Process remaining audio
        if accumulated.count > Int(MeetingService.sampleRate) {
            transcriber.transcribeSegment(accumulated, timestamp: segmentStartTime)
        }
        accumulated = [] // Release memory immediately

        // Wait for any in-flight transcription to complete
        await service.pendingTranscriptionTask?.value
        service.pendingTranscriptionTask = nil

        // Stop captures
        inputNode.removeTap(onBus: 0)
        micEngine.stop()
        service.audioEngine = nil

        if let stream = service.scStream {
            try? await stream.stopCapture()
            service.scStream = nil
        }

        // Skip persisting the meeting at all if no speech was captured —
        // user toggled record then walked away from the mic, no point
        // saving an empty header-only markdown or running the summary LLM.
        let isEmptyMeeting = writer.transcribedSegmentCount == 0

        // Finalize the screen recording before touching files. An empty meeting
        // discards the .mov along with the markdown/WAV; otherwise await the
        // writer so the .mov is fully flushed.
        if let recorder = service.screenRecorder {
            if isEmptyMeeting {
                recorder.cancel()
            } else {
                _ = await recorder.finish()
            }
            service.screenRecorder = nil
        }

        // Close the audio file before touching the filesystem — releases the
        // handle so we can delete it cleanly if the meeting was empty.
        writer.audioFile = nil

        if isEmptyMeeting, let path = writer.markdownFilePath {
            try? FileManager.default.removeItem(atPath: path)
            if let audioPath = writer.audioFilePath {
                try? FileManager.default.removeItem(atPath: audioPath)
            }
            writer.audioFilePath = nil
            NSLog("%@", "[MeetingService] Discarded empty meeting (no transcribed segments).")
            writer.markdownFilePath = nil
        } else {
            writer.finalizeMarkdown(startTime: service.startTime)
            // A meeting with content just completed — History tab opens on
            // the meeting segment next.
            configManager.lastHistoryKind = "meeting"
            NotificationCenter.default.post(name: .meetingFilesDidChange, object: nil)
        }

        // Unload the meeting's own ASR model — meetings own this instance
        // (it is not shared with voice input) and free it between meetings so
        // it occupies no memory while idle.
        service.asrEngine?.unload()
        service.asrEngine = nil
        service.vadModel = nil

        // Recording + file finalization are done. Re-enable voice input and
        // return to .idle NOW so the user can start the next meeting the
        // instant they want — LLM summarization is a slow network call and
        // must not sit on the critical path between meetings (a double-Command
        // during summarization used to be silently swallowed).
        service.voiceService?.setMeetingActive(false)
        service.state = .idle

        // Auto-summarize in a detached background task. `processingMarkdownPath`
        // stays set so the History tab keeps the "生成中" badge on this file
        // until the summary lands; the detached task clears it when done —
        // but only if a newer meeting hasn't since claimed the badge.
        if !isEmptyMeeting, configManager.meetingLLMEnabled,
           let path = writer.markdownFilePath {
            Task { @MainActor [weak service] in
                guard let service else { return }
                service.summaryError = nil
                do {
                    try await service.summarizer.summarize(transcriptPath: path)
                    NotificationCenter.default.post(name: .meetingFilesDidChange, object: nil)
                } catch {
                    service.summaryError = error.localizedDescription
                    NSLog("%@", "[MeetingService] Summarization failed: \(error)")
                }
                if service.processingMarkdownPath == path {
                    service.processingMarkdownPath = nil
                }
            }
        } else {
            service.processingMarkdownPath = nil
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
            sysAudio = resample(rawSys, from: MeetingService.sckSampleRate, to: MeetingService.sampleRate)
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
        let sysScale = MeetingService.targetRMS / (sysRMS + MeetingService.epsilon) * 0.5

        var micRMS: Float = 0
        vDSP_rmsqv(micAudio, 1, &micRMS, vDSP_Length(maxLen))
        let micScale = MeetingService.targetRMS / (micRMS + MeetingService.epsilon) * 0.5

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
        guard let vad = service?.vadModel else { return nil }

        let sampleRateInt = Int(MeetingService.sampleRate)
        let segments = vad.detectSpeech(audio: audio, sampleRate: sampleRateInt)

        if segments.isEmpty {
            return audio.count
        }

        let sampleRateFloat = Float(MeetingService.sampleRate)
        let silenceSamples = Int(Float(MeetingService.vadSilenceThreshold) * sampleRateFloat)
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
}
