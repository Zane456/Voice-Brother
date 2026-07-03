import AVFoundation
import Foundation

/// Owns the meeting's on-disk artifacts: the timestamped Markdown transcript
/// and the raw mixed-audio WAV. Also holds the soft-merge state that turns
/// hundreds of one-line VAD segments into a few readable paragraphs.
///
/// Split out of `MeetingService` (phase B). The facade owns the lifecycle and
/// reads this writer's file paths / segment count; the recording loop feeds it
/// audio samples and warning lines; the segment transcriber feeds it text.
@MainActor
final class MeetingTranscriptWriter {

    // MARK: - Soft-merge tuning

    /// A gap of this many seconds between two segments forces a new paragraph.
    /// Tuned for typical meeting cadence — most genuine topic shifts include
    /// at least this much silence; sub-30s gaps usually mean the same speaker
    /// is continuing the same thought.
    private static let paragraphSilenceGap: TimeInterval = 30
    /// Force a new paragraph after this much continuous content even without
    /// a long silence, so we don't end up with a single 30-minute paragraph
    /// during a monologue.
    private static let paragraphMaxDuration: TimeInterval = 180

    // MARK: - File State

    var markdownFilePath: String?
    /// Streaming-writer for the raw mixed recording (Int16 PCM WAV at 16 kHz).
    /// Written in the same loop that mixes audio for ASR, so we don't double
    /// the CPU cost of resampling. Deleted at finalize if the meeting was
    /// empty (no speech captured).
    var audioFile: AVAudioFile?
    var audioFilePath: String?
    /// Absolute path of the screen-recording `.mov` for the current meeting.
    /// Set in `initMarkdown` alongside the markdown/WAV paths so all three
    /// share one timestamp; the recorder is only created if screen recording
    /// is enabled.
    var videoFilePath: String?
    /// Counts non-empty transcription segments written to the markdown file.
    /// Used to skip saving + summarising when a meeting captured no speech
    /// (e.g. user toggled recording then walked away from the mic).
    var transcribedSegmentCount: Int = 0

    /// Pre-allocated format used to hand Float32 samples to AVAudioFile, which
    /// internally transcodes to Int16 LPCM for the WAV file.
    private lazy var audioWriteFormat: AVAudioFormat? =
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: MeetingService.sampleRate,
                      channels: 1,
                      interleaved: false)

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

    // MARK: - Markdown File Management

    func initMarkdown(startTime: Date?, savePath: String) {
        guard let start = startTime else { return }

        do {
            try FileManager.default.createDirectory(atPath: savePath, withIntermediateDirectories: true)
        } catch {
            NSLog("%@", "[MeetingService] Failed to create save directory: \(error)")
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
            AVSampleRateKey: MeetingService.sampleRate,
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
            NSLog("%@", "[MeetingService] Failed to open audio WAV for writing: \(error)")
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

    func finalizeMarkdown(startTime: Date?) {
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
            NSLog("%@", "[MeetingService] Failed to finalize markdown: \(error)")
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
    func appendSegment(timestamp: Date, text: String) {
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
    func appendAudioSamples(_ samples: [Float]) {
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
            NSLog("%@", "[MeetingService] Audio WAV write failed: \(error) — dropping future samples")
            self.audioFile = nil
        }
    }

    func writeToFile(_ content: String) {
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
}
