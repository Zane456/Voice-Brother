import AppKit
import Foundation

/// Parses `--retranscribe` CLI arguments and dispatches the offline
/// re-transcription pipeline. Used as an early-exit branch in
/// VoiceBubbleApp.init so the full SwiftUI app never starts.
enum MeetingRetranscribeLauncher {

    struct Args {
        let wavPath: String
        /// nil or "Auto" → auto-detect (drops the language hint).
        let language: String?
        let outputMarkdownPath: String
        let modelId: String
    }

    static func parseArgs(_ argv: [String]) -> Args? {
        guard let idx = argv.firstIndex(of: "--retranscribe") else { return nil }
        let rest = Array(argv.dropFirst(idx + 1))
        guard rest.count >= 3 else {
            print("[Retranscribe] Usage: --retranscribe <wav> <language> <output_md> [model_id]")
            exit(2)
        }
        let modelId = rest.count >= 4 ? rest[3] : "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
        // Treat "Auto", "auto", "" or "-" as nil so the CLI can opt into
        // auto-detect without inventing a sentinel string.
        let lang: String?
        switch rest[1].lowercased() {
        case "", "auto", "-": lang = nil
        default: lang = rest[1]
        }
        return Args(
            wavPath: rest[0],
            language: lang,
            outputMarkdownPath: rest[2],
            modelId: modelId
        )
    }

    /// Runs the re-transcription synchronously then exits the process.
    /// Pumps the AppKit event loop while waiting so AVAudioFile, MLX, etc
    /// can drive their internal queues without the app's normal scene hooks.
    static func runAndExit(options: Args) -> Never {
        // Try to extract a meeting start date from the WAV filename
        // (e.g. "会议录音_2026-05-03_20-04-46.wav").
        let meetingStart = extractStartDate(from: options.wavPath)

        // Drive the async work from the main thread. We use a semaphore to
        // bridge — but we must keep the runloop spinning so AppKit-backed
        // APIs (AVAudioConverter, etc) make progress.
        let runOptions = MeetingRetranscriber.Options(
            wavPath: options.wavPath,
            outputMarkdownPath: options.outputMarkdownPath,
            language: options.language,
            modelId: options.modelId,
            meetingStartDate: meetingStart
        )

        let done = DispatchSemaphore(value: 0)
        var caught: Error?
        Task.detached(priority: .userInitiated) {
            do {
                try await MeetingRetranscriber.run(options: runOptions)
            } catch {
                caught = error
            }
            done.signal()
        }

        // Spin the main runloop until the task finishes.
        while done.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        if let error = caught {
            print("[Retranscribe] FAILED: \(error.localizedDescription)")
            exit(1)
        }
        print("[Retranscribe] DONE")
        exit(0)
    }

    private static func extractStartDate(from wavPath: String) -> Date? {
        let name = (wavPath as NSString).lastPathComponent
        // Match yyyy-MM-dd_HH-mm-ss anywhere in the basename.
        let pattern = "([0-9]{4})-([0-9]{2})-([0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard let m = regex.firstMatch(in: name, range: range), m.numberOfRanges == 7 else { return nil }
        func grp(_ i: Int) -> Int? {
            guard let r = Range(m.range(at: i), in: name) else { return nil }
            return Int(name[r])
        }
        guard let y = grp(1), let mo = grp(2), let d = grp(3),
              let hh = grp(4), let mm = grp(5), let ss = grp(6) else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        comps.hour = hh; comps.minute = mm; comps.second = ss
        return Calendar.current.date(from: comps)
    }
}
