import Foundation

/// Structured ASR-lifecycle event stream — Voice Brother's local equivalent of
/// 豆包输入法 `[ASR][Lifecycle]` log channel.
///
/// Every voice or meeting session gets a UUID; every state transition writes
/// one JSON line to `/tmp/vb_asr_events.log`. When debugging glitches like
/// "press-to-talk start delay" or "panel stuck visible", `tail -f` + `jq` shows
/// exactly which step stalled.
///
/// Runs on its own serial queue and is best-effort — a logging failure can
/// never propagate into the recording path. Parallel to `DebugLog`; both keep
/// writing.
enum ASREvent: String {
    // Session lifecycle
    case sessionBegin = "session_begin"
    case sessionEnd = "session_end"
    case resetSessionState = "reset_session_state"

    // Key / trigger
    case keyPress = "key_press"
    case keyRelease = "key_release"
    case meetingGestureDetected = "meeting_gesture_detected"

    // Recording
    case recordingStarted = "recording_started"
    case recordingStopped = "recording_stopped"
    case audioEngineRecoveryAttempt = "audio_engine_recovery_attempt"

    // Panel
    case panelPresentRecording = "panel_present_recording"
    case panelPresentNonRecording = "panel_present_non_recording"
    case panelHidden = "panel_hidden"

    // ASR engine
    case asrStarted = "asr_started"
    case asrFinished = "asr_finished"
    case asrFailed = "asr_failed"
    case partialReceived = "partial_received"
    case finalReceived = "final_received"
    case dropLateResult = "drop_late_result"

    // Post-processing
    case processStarted = "process_started"
    case processCompleted = "process_completed"
    case llmPolishStarted = "llm_polish_started"
    case llmPolishCompleted = "llm_polish_completed"
    case llmPolishFailed = "llm_polish_failed"

    // Injection
    case injectStarted = "inject_started"
    case injectCompleted = "inject_completed"
    case injectFailed = "inject_failed"

    // Stops / interrupts
    case stopRequested = "stop_requested"
    case stopCompleted = "stop_completed"
    case interruptEsc = "interrupt_esc"
    case interruptFocusChange = "interrupt_focus_change"
    case interruptMeetingToggle = "interrupt_meeting_toggle"
    case interruptMicOccupied = "interrupt_mic_occupied"
    case interruptConfigChange = "interrupt_config_change"

    // Meeting state machine (parallel to voice; same logger)
    case meetingPreparing = "meeting_preparing"
    case meetingRecording = "meeting_recording"
    case meetingFinishing = "meeting_finishing"
    case meetingIdle = "meeting_idle"
    case meetingSegmentStarted = "meeting_segment_started"
    case meetingSegmentTranscribed = "meeting_segment_transcribed"
}

final class ASRLogger {

    static let shared = ASRLogger()

    enum Scope: String {
        case voice
        case meeting
    }

    private let path = "/tmp/vb_asr_events.log"
    private let maxSize: UInt64 = 1_048_576   // 1 MB per file
    private let maxRotations = 5              // .log + .log.1..4
    private let queue = DispatchQueue(label: "com.voicebrother.asrlogger", qos: .utility)
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Write one event. `sessionID` short-hashes to 8 chars so a `tail -f` is
    /// readable. `props` accepts any JSON-encodable scalars; anything else is
    /// coerced to its `String(describing:)` form so a bad call never throws.
    func event(_ kind: ASREvent,
               sessionID: UUID? = nil,
               scope: Scope = .voice,
               props: [String: Any] = [:]) {
        let ts = iso.string(from: Date())
        var dict: [String: Any] = [
            "ts": ts,
            "kind": kind.rawValue,
            "scope": scope.rawValue
        ]
        if let sid = sessionID {
            dict["session"] = String(sid.uuidString.prefix(8))
        }
        for (k, v) in props {
            dict[k] = Self.sanitize(v)
        }
        queue.async { [weak self] in
            self?.writeLine(dict)
        }
    }

    private static func sanitize(_ v: Any) -> Any {
        switch v {
        case is String, is Int, is Double, is Bool, is NSNull: return v
        default: return String(describing: v)
        }
    }

    private func writeLine(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        guard let bytes = line.data(using: .utf8) else { return }

        rotateIfNeeded()

        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile()
                fh.write(bytes)
                fh.closeFile()
            }
        } else {
            fm.createFile(atPath: path, contents: bytes)
        }
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64,
              size > maxSize else { return }

        // .log.(N-1) drops off, .log.(N-2) -> .log.(N-1), ..., .log -> .log.1
        let oldest = "\(path).\(maxRotations - 1)"
        try? fm.removeItem(atPath: oldest)
        for i in stride(from: maxRotations - 1, through: 1, by: -1) {
            let src = i == 1 ? path : "\(path).\(i - 1)"
            let dst = "\(path).\(i)"
            if fm.fileExists(atPath: src) {
                if fm.fileExists(atPath: dst) { try? fm.removeItem(atPath: dst) }
                try? fm.moveItem(atPath: src, toPath: dst)
            }
        }
    }
}

// MARK: - Convenience

extension ASRLogger {
    /// `dur_ms` helper for callers measuring latency.
    static func durMs(since: Date) -> Int {
        Int(Date().timeIntervalSince(since) * 1000)
    }
}
