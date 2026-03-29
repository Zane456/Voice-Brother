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

    // MARK: - Dependencies

    private let configManager: ConfigManager
    private weak var voiceService: VoiceService?

    // MARK: - Internal State

    private var asrModel: Qwen3ASRModel?
    private var vadModel: SileroVADModel?
    private var audioEngine: AVAudioEngine?
    private var scStream: SCStream?
    private nonisolated(unsafe) let audioBuffer = AudioChunkBuffer()
    private var startTime: Date?
    private var markdownFilePath: String?
    private var elapsedTimer: Timer?
    private var recordingTask: Task<Void, Never>?

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
    }

    // MARK: - MeetingServiceProtocol

    func start() {
        guard state == .idle else { return }

        // Ensure the voice service has loaded a model (model must be cached)
        let modelString = configManager.model
        guard let model = ASRModel(rawValue: modelString) else {
            state = .error("无效的模型配置")
            return
        }

        savePath = configManager.meetingSavePath
        state = .recording
        startTime = Date()
        elapsedSeconds = 0

        startElapsedTimer()

        // Suppress single-key voice input during meeting
        voiceService?.keyboardListenerRef?.isMeetingActive = true

        // Show recording indicator for the duration of the meeting
        RecordingOverlayPanel.shared.show()

        recordingTask = Task { @MainActor in
            do {
                // Share the already-loaded model from voice service (no reload needed).
                // Safe because voice recording is suppressed during meetings (meetingActive = true).
                guard let asr = self.voiceService?.asrModel else {
                    self.state = .error("语音服务未加载模型")
                    self.voiceService?.keyboardListenerRef?.isMeetingActive = false
                    RecordingOverlayPanel.shared.hide()
                    return
                }
                self.asrModel = asr

                // Load VAD model (small, loads quickly)
                let vad = try await SileroVADModel.fromPretrained(engine: .coreml)
                self.vadModel = vad

                guard !Task.isCancelled else {
                    self.asrModel = nil  // Don't unload — shared with voice service
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
                self.cleanup()
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
        case .finishing:
            // Already finishing, do nothing
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
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            print("[MeetingService] Failed to finalize markdown: \(error)")
        }
    }

    private func appendSegment(timestamp: Date, text: String) {
        guard let _ = markdownFilePath else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let tsStr = formatter.string(from: timestamp)
        writeToFile("**[\(tsStr)]** \(text)\n\n")
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

        // Start system audio capture via ScreenCaptureKit
        var sysAudioStarted = false
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
            sysAudioStarted = true
        } catch {
            print("[MeetingService] System audio capture failed: \(error). Continuing with microphone only.")
            // Continue with mic only
        }

        // Main recording loop
        var accumulated: [Float] = []
        var segmentStartTime = Date()

        while isRecording {
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

            // Collect buffered audio
            let (currentMic, currentSys) = audioBuffer.swapAll()

            // Mix audio
            if let mixed = mixAudio(sysChunks: currentSys, micChunks: currentMic), !mixed.isEmpty {
                accumulated.append(contentsOf: mixed)
            }

            let duration = Double(accumulated.count) / Self.sampleRate

            if duration >= Self.vadMinAccumulate {
                let cutPoint = findCutPoint(in: accumulated)

                if cutPoint != nil || duration >= Self.vadForceCut {
                    let actualCut = cutPoint ?? accumulated.count
                    let overlapSamples = Int(Self.vadOverlap * Self.sampleRate)
                    let segment = Array(accumulated.prefix(actualCut))
                    accumulated = Array(accumulated.dropFirst(max(0, actualCut - overlapSamples)))

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

        // Stop captures
        inputNode.removeTap(onBus: 0)
        micEngine.stop()
        self.audioEngine = nil

        if let stream = scStream {
            try? await stream.stopCapture()
            self.scStream = nil
        }

        // Finalize markdown
        finalizeMarkdown()

        // Release model references (don't unload — ASR model is shared with voice service)
        asrModel = nil
        vadModel = nil

        // Re-enable single-key voice input now that finalization is complete
        voiceService?.keyboardListenerRef?.isMeetingActive = false

        // Update state
        state = .idle
    }

    // MARK: - Audio Mixing

    private func mixAudio(sysChunks: [[Float]], micChunks: [[Float]]) -> [Float]? {
        // Process system audio: concatenate and resample from 48kHz to 16kHz
        var sysAudio: [Float] = []
        if !sysChunks.isEmpty {
            let rawSys = sysChunks.flatMap { $0 }
            if !rawSys.isEmpty {
                sysAudio = resample(rawSys, from: Self.sckSampleRate, to: Self.sampleRate)
            }
        }

        // Process microphone audio: concatenate
        var micAudio: [Float] = []
        if !micChunks.isEmpty {
            micAudio = micChunks.flatMap { $0 }
        }

        if sysAudio.isEmpty && micAudio.isEmpty {
            return nil
        }

        // Zero-pad to same length
        let maxLen = max(sysAudio.count, micAudio.count)
        if sysAudio.count < maxLen {
            sysAudio.append(contentsOf: [Float](repeating: 0, count: maxLen - sysAudio.count))
        }
        if micAudio.count < maxLen {
            micAudio.append(contentsOf: [Float](repeating: 0, count: maxLen - micAudio.count))
        }

        // RMS normalization
        let sysRMS = sqrt(sysAudio.reduce(0) { $0 + $1 * $1 } / Float(sysAudio.count)) + Self.epsilon
        let micRMS = sqrt(micAudio.reduce(0) { $0 + $1 * $1 } / Float(micAudio.count)) + Self.epsilon

        let sysNorm = sysAudio.map { $0 * (Self.targetRMS / sysRMS) }
        let micNorm = micAudio.map { $0 * (Self.targetRMS / micRMS) }

        // 50/50 mix
        return zip(sysNorm, micNorm).map { 0.5 * $0 + 0.5 * $1 }
    }

    /// Simple linear interpolation resampling.
    private func resample(_ input: [Float], from inputRate: Double, to outputRate: Double) -> [Float] {
        guard inputRate != outputRate, !input.isEmpty else { return input }
        let ratio = inputRate / outputRate
        let outputCount = Int(Double(input.count) / ratio)
        guard outputCount > 0 else { return [] }

        var output = [Float]()
        output.reserveCapacity(outputCount)

        for i in 0..<outputCount {
            let srcIdx = Double(i) * ratio
            let idx0 = Int(srcIdx)
            let frac = Float(srcIdx - Double(idx0))

            if idx0 + 1 < input.count {
                output.append(input[idx0] * (1 - frac) + input[idx0 + 1] * frac)
            } else if idx0 < input.count {
                output.append(input[idx0])
            }
        }

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

        for i in 0..<(segments.count - 1) {
            let gapStart = Int(segments[i].endTime * sampleRateFloat)
            let gapEnd = Int(segments[i + 1].startTime * sampleRateFloat)
            if (gapEnd - gapStart) >= silenceSamples {
                return (gapStart + gapEnd) / 2
            }
        }

        return nil
    }

    // MARK: - Transcription

    private func transcribeSegment(_ audio: [Float], timestamp: Date) {
        guard let model = asrModel else {
            appendSegment(timestamp: timestamp, text: "[转写失败：模型未加载]")
            return
        }

        // transcribe() is synchronous — not async
        let text = model.transcribe(
            audio: audio,
            sampleRate: Int(Self.sampleRate),
            language: "Chinese"
        )

        let processed = TextProcessor.removeFillers(from: text)
        if !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendSegment(timestamp: timestamp, text: processed)
        }
    }

    // MARK: - Cleanup

    private func cleanup() {
        stopElapsedTimer()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        if let stream = scStream {
            Task { try? await stream.stopCapture() }
            scStream = nil
        }

        asrModel = nil  // Don't unload — shared with voice service
        vadModel = nil

        finalizeMarkdown()
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

    var systemChunks: [[Float]] {
        get { _lock.withLock { _sysChunks } }
        set { _lock.withLock { _sysChunks = newValue } }
    }

    func appendMic(_ chunk: [Float]) {
        _lock.lock()
        _micChunks.append(chunk)
        _lock.unlock()
    }

    func appendSystem(_ chunk: [Float]) {
        _lock.lock()
        _sysChunks.append(chunk)
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
