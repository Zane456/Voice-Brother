import Foundation
import Qwen3ASR
import SpeechVAD

/// Runs ASR on each VAD-cut segment and feeds the cleaned text to the
/// transcript writer. Split out of `MeetingService` (phase B).
///
/// The `pendingTranscriptionTask` handle stays on the facade (`cleanup` /
/// `runRecording` await it); this collaborator only reads/writes it through the
/// weak `service` back-reference so the serialization chain is unchanged.
@MainActor
final class MeetingSegmentTranscriber {

    private let writer: MeetingTranscriptWriter
    private let configManager: ConfigManager
    weak var service: MeetingService?

    init(writer: MeetingTranscriptWriter, configManager: ConfigManager) {
        self.writer = writer
        self.configManager = configManager
    }

    /// @MainActor bridge for the detached transcription task to hand its
    /// cleaned text back to the writer (identical call site to the original,
    /// where `appendSegment` lived on `MeetingService`).
    private func appendSegment(timestamp: Date, text: String) {
        writer.appendSegment(timestamp: timestamp, text: text)
    }

    func transcribeSegment(_ audio: [Float], timestamp: Date) {
        guard let service, let engine = service.asrEngine else {
            appendSegment(timestamp: timestamp, text: "[转写失败：模型未加载]")
            return
        }

        // Compact long internal silences before sending to ASR. Long pauses
        // inside a chunk cause Qwen3-ASR to fall into token-loop sampling
        // (e.g. "はい。はい。はい…" or "我我我…"). VAD picks the speech
        // regions and we concatenate them with a short pad — the model sees
        // continuous speech, output stays clean.
        let compacted = compactSilences(in: audio, vad: service.vadModel)

        // Wait for previous transcription to finish before starting a new one,
        // preventing unbounded task accumulation and memory pressure.
        let previousTask = service.pendingTranscriptionTask
        let capturedAudio = compacted
        let sampleRate = Int(MeetingService.sampleRate)

        let sessionID = service.currentSessionID
        ASRLogger.shared.event(.meetingSegmentStarted, sessionID: sessionID, scope: .meeting,
                               props: ["samples": compacted.count,
                                       "dur_s": Double(compacted.count) / Double(MeetingService.sampleRate)])

        service.pendingTranscriptionTask = Task.detached { [weak self] in
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
    func compactSilences(in audio: [Float], vad: SileroVADModel?) -> [Float] {
        guard let vad else { return audio }
        let sr = Int(MeetingService.sampleRate)
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
}
