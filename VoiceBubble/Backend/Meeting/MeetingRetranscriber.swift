import AVFoundation
import Foundation
import Qwen3ASR
import SpeechVAD

/// One-shot offline re-transcription of an existing meeting recording.
///
/// Reads a previously-saved 16 kHz mono WAV (whatever MeetingService wrote),
/// segments it with SileroVAD using the same cut-point logic as the live
/// pipeline, transcribes each segment with Qwen3-ASR in the requested language,
/// and emits a fresh markdown alongside the original.
///
/// Used to recover meetings that were transcribed under the wrong language hint
/// (e.g. a Japanese conversation captured while the model was set to Chinese).
enum MeetingRetranscriber {

    private static let sampleRate: Int = 16000
    private static let vadMinAccumulateSec: Double = 20.0
    private static let vadForceCutSec: Double = 40.0
    private static let vadSilenceThresholdSec: Double = 0.8
    private static let vadOverlapSec: Double = 0.5
    private static let paragraphSilenceGapSec: TimeInterval = 30
    private static let paragraphMaxDurationSec: TimeInterval = 180

    struct Options {
        let wavPath: String
        let outputMarkdownPath: String
        /// Language string accepted by Qwen3-ASR (e.g. "Japanese", "Chinese", "English").
        /// nil or "Auto" → auto-detect (drops the language hint).
        let language: String?
        /// HuggingFace ID for the Qwen3 ASR model to load.
        let modelId: String
        /// Wall-clock start of the meeting, used to label segment timestamps.
        /// If nil, timestamps start at 00:00:00.
        let meetingStartDate: Date?
    }

    static func run(options: Options) async throws {
        let logPrefix = "[Retranscribe]"
        print("\(logPrefix) wav=\(options.wavPath)")
        print("\(logPrefix) out=\(options.outputMarkdownPath)")
        print("\(logPrefix) language=\(options.language ?? "Auto") model=\(options.modelId)")

        // 1. Load the WAV as Float32 mono at 16 kHz
        let samples = try loadMonoFloatSamples(at: options.wavPath, targetSampleRate: Double(sampleRate))
        let totalDurationSec = Double(samples.count) / Double(sampleRate)
        print(String(format: "%@ loaded %d samples (%.1fs)", logPrefix, samples.count, totalDurationSec))

        // 2. Load Qwen3-ASR + SileroVAD
        print("\(logPrefix) loading Qwen3-ASR…")
        let asrModel = try await Qwen3ASRModel.fromPretrained(
            modelId: options.modelId,
            progressHandler: { progress, status in
                print(String(format: "%@   asr-load %.0f%% — %@", logPrefix, progress * 100, status))
            }
        )
        print("\(logPrefix) loading SileroVAD…")
        let vad = try await SileroVADModel.fromPretrained(engine: .coreml)

        // 3. Walk the buffer with VAD-driven cuts (same algorithm as MeetingService.runRecording).
        let forceCutSamples = Int(vadForceCutSec * Double(sampleRate))
        let minAccSamples = Int(vadMinAccumulateSec * Double(sampleRate))
        let overlapSamples = Int(vadOverlapSec * Double(sampleRate))

        var segments: [(startSec: Double, text: String)] = []
        var cursor = 0
        let progressStep = max(1, samples.count / 50) // log every ~2%
        var nextProgressMark = progressStep
        var segmentsSinceFlush = 0
        let flushEvery = 5

        let meetingStart = options.meetingStartDate ?? Date()
        // Incremental flush helper — write what we have so a mid-run crash
        // still leaves a usable partial transcript on disk.
        func flushToDisk() {
            let md = renderMarkdown(
                segments: segments,
                totalDurationSec: totalDurationSec,
                meetingStartDate: meetingStart,
                language: options.language
            )
            try? md.write(toFile: options.outputMarkdownPath, atomically: true, encoding: .utf8)
        }

        while cursor < samples.count {
            // Wrap each iteration in an autoreleasepool — CoreML's VAD and
            // Qwen3ASR's MLX inference both allocate IOSurfaces / autoreleased
            // buffers that only drain when the pool exits. In the live meeting
            // pipeline the 0.5s Task.sleep between iterations gives the runloop
            // a chance to drain; here we hammer them in a tight loop, so the
            // surfaces accumulate until IOSurface allocation fails (~13 chunks
            // in a 1.7B run). Explicit pool keeps memory flat.
            try autoreleasepool { () throws -> Void in
                let windowEnd = min(cursor + forceCutSamples, samples.count)
                let windowLen = windowEnd - cursor
                let windowStartSec = Double(cursor) / Double(sampleRate)

                let cutInWindow: Int
                if windowLen <= minAccSamples {
                    cutInWindow = windowLen
                } else {
                    let window = Array(samples[cursor..<windowEnd])
                    if let cut = findCutPoint(in: window, vad: vad) {
                        cutInWindow = max(1, min(cut, windowLen))
                    } else {
                        cutInWindow = windowLen
                    }
                }

                let segment = Array(samples[cursor..<(cursor + cutInWindow)])
                let segDurationSec = Double(segment.count) / Double(sampleRate)

                // Transcribe (synchronous; Qwen3ASRModel is not thread-safe so we
                // serialise here on purpose).
                let raw = asrModel.transcribe(
                    audio: segment,
                    sampleRate: sampleRate,
                    language: options.language,
                    context: nil
                )
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    segments.append((startSec: windowStartSec, text: trimmed))
                    let preview = String(trimmed.prefix(40)).replacingOccurrences(of: "\n", with: " ")
                    print(String(format: "%@   %@ (%.1fs) %@", logPrefix, formatHMS(windowStartSec), segDurationSec, preview))
                } else {
                    print(String(format: "%@   %@ (%.1fs) <empty>", logPrefix, formatHMS(windowStartSec), segDurationSec))
                }
                fflush(stdout)

                let advance = max(1, cutInWindow - overlapSamples)
                cursor += advance

                segmentsSinceFlush += 1
                if segmentsSinceFlush >= flushEvery {
                    flushToDisk()
                    segmentsSinceFlush = 0
                }

                if cursor >= nextProgressMark {
                    let pct = Double(cursor) / Double(samples.count) * 100
                    print(String(format: "%@ progress %.1f%% (%@/%@)", logPrefix, pct, formatHMS(Double(cursor) / Double(sampleRate)), formatHMS(totalDurationSec)))
                    fflush(stdout)
                    nextProgressMark = cursor + progressStep
                }
            }
        }

        // 4. Final flush — render markdown with paragraph soft-merging similar
        // to MeetingService.
        flushToDisk()
        print("\(logPrefix) wrote markdown -> \(options.outputMarkdownPath)")

        // Release the model (Qwen3ASRModel.unload is the polite cleanup)
        asrModel.unload()
    }

    // MARK: - WAV loading

    private static func loadMonoFloatSamples(at path: String, targetSampleRate: Double) throws -> [Float] {
        let url = URL(fileURLWithPath: path)
        let file = try AVAudioFile(forReading: url)
        let processingFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "MeetingRetranscriber", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not allocate input buffer"])
        }
        try file.read(into: inputBuffer)

        // Convert to Float32 mono at targetSampleRate via AVAudioConverter.
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "MeetingRetranscriber", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not build output format"])
        }

        if processingFormat.sampleRate == targetSampleRate &&
            processingFormat.channelCount == 1 &&
            processingFormat.commonFormat == .pcmFormatFloat32 {
            // Already mono float at target rate
            guard let data = inputBuffer.floatChannelData else { return [] }
            let count = Int(inputBuffer.frameLength)
            return Array(UnsafeBufferPointer(start: data[0], count: count))
        }

        guard let converter = AVAudioConverter(from: processingFormat, to: outputFormat) else {
            throw NSError(domain: "MeetingRetranscriber", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not build converter"])
        }

        let ratio = targetSampleRate / processingFormat.sampleRate
        let outFrameCapacity = AVAudioFrameCount(Double(frameCount) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outFrameCapacity) else {
            throw NSError(domain: "MeetingRetranscriber", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not allocate output buffer"])
        }

        var supplied = false
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if supplied {
                outStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if status == .error, let err = convError {
            throw err
        }

        guard let outData = outBuffer.floatChannelData else { return [] }
        let count = Int(outBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: outData[0], count: count))
    }

    // MARK: - VAD

    private static func findCutPoint(in audio: [Float], vad: SileroVADModel) -> Int? {
        let segs = vad.detectSpeech(audio: audio, sampleRate: sampleRate)
        if segs.isEmpty {
            return audio.count
        }

        let silenceSamples = Int(vadSilenceThresholdSec * Double(sampleRate))
        let audioCount = audio.count
        let sampleRateFloat = Float(sampleRate)

        for i in 0..<(segs.count - 1) {
            let rawGapStart = Int(segs[i].endTime * sampleRateFloat)
            let rawGapEnd = Int(segs[i + 1].startTime * sampleRateFloat)
            let gapStart = max(0, min(rawGapStart, audioCount))
            let gapEnd = max(gapStart, min(rawGapEnd, audioCount))
            if (gapEnd - gapStart) >= silenceSamples {
                return min((gapStart + gapEnd) / 2, audioCount)
            }
        }
        return nil
    }

    // MARK: - Markdown

    private static func renderMarkdown(
        segments: [(startSec: Double, text: String)],
        totalDurationSec: Double,
        meetingStartDate: Date,
        language: String?
    ) -> String {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        let stampFmt = DateFormatter()
        stampFmt.dateFormat = "HH:mm:ss"

        let totalMinutes = Int(totalDurationSec / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let durationStr = hours > 0 ? "\(hours)小时\(minutes)分钟" : "\(minutes)分钟"

        var lines: [String] = []
        lines.append("# 会议纪要（重转写：\(language ?? "Auto")）")
        lines.append("")
        lines.append("- 日期：\(dateFmt.string(from: meetingStartDate))")
        lines.append("- 时间：\(timeFmt.string(from: meetingStartDate)) -")
        lines.append("- 时长：\(durationStr)")
        lines.append("")
        lines.append("---")

        // Soft-merge: emit a new paragraph whenever there's a >=30s gap between
        // segments or the running paragraph exceeds 3 minutes.
        var paragraphStartSec: Double? = nil
        var lastSegSec: Double = 0
        var paragraphLines: [String] = []
        var lastText: String = ""

        func flushParagraph() {
            if let startSec = paragraphStartSec, !paragraphLines.isEmpty {
                let stamp = stampFmt.string(from: meetingStartDate.addingTimeInterval(startSec))
                lines.append("**[\(stamp)]** " + paragraphLines.joined(separator: " "))
                lines.append("")
            }
            paragraphStartSec = nil
            paragraphLines = []
        }

        for seg in segments {
            // Drop trivial duplicates that ASR sometimes emits across
            // overlapping windows.
            if seg.text == lastText { continue }
            lastText = seg.text

            if let pStart = paragraphStartSec {
                let gap = seg.startSec - lastSegSec
                let paragraphAge = seg.startSec - pStart
                if gap >= paragraphSilenceGapSec || paragraphAge >= paragraphMaxDurationSec {
                    flushParagraph()
                }
            }

            if paragraphStartSec == nil {
                paragraphStartSec = seg.startSec
            }
            paragraphLines.append(seg.text)
            lastSegSec = seg.startSec
        }
        flushParagraph()

        return lines.joined(separator: "\n") + "\n"
    }

    private static func formatHMS(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}
