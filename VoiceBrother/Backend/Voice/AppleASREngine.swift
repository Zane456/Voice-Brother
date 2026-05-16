import Foundation
import Speech

/// Apple SFSpeechRecognizer wrapper conforming to ASREngineProtocol.
/// On-device only recognition. Failable init — returns nil if on-device recognition
/// isn't supported on this hardware OR if the zh-Hans on-device language model isn't
/// installed (System Settings → 键盘 → 听写 → 添加中文).
///
/// IMPORTANT: transcribe() blocks the calling thread with a semaphore. Must be called
/// from a background thread (Task.detached).
final class AppleASREngine: ASREngineProtocol {
    /// On-device recognizers keyed by the ASR `language` hint ("Chinese" /
    /// "English" / "Japanese"). Built once at init and never mutated, so the
    /// engine stays immutable and lock-free even though transcribe() runs on
    /// background threads.
    private let recognizers: [String: SFSpeechRecognizer]
    /// Used when `language` is nil (auto-detect) or maps to a locale whose
    /// on-device asset isn't installed. SFSpeechRecognizer cannot auto-detect
    /// across languages, so auto-detect meetings fall back to Chinese.
    private let defaultRecognizer: SFSpeechRecognizer

    /// Maps MeetingLanguage's `asrLanguageHint` values to BCP-47 locale IDs.
    private static let localeForLanguage: [String: String] = [
        "Chinese": "zh-Hans",
        "English": "en-US",
        "Japanese": "ja-JP",
    ]

    /// Failable init. Returns nil if the device can't run on-device Chinese
    /// recognition at all. Japanese/English recognizers are best-effort — if
    /// their on-device assets aren't installed they're simply omitted, and
    /// transcribe() then falls back to Chinese for that language.
    init?() {
        var built: [String: SFSpeechRecognizer] = [:]
        for (hint, localeID) in Self.localeForLanguage {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else {
                NSLog("[AppleASREngine] Failed to create SFSpeechRecognizer for %@ (%@)", hint, localeID)
                continue
            }
            guard recognizer.supportsOnDeviceRecognition else {
                NSLog("[AppleASREngine] On-device recognition not supported for %@ (%@)", hint, localeID)
                continue
            }
            // `isAvailable` flips to false when the on-device language asset isn't present
            // (most common cause: user hasn't added that language in System Settings →
            // Keyboard → Dictation). We log a warning rather than skipping it — the asset
            // might still download in the background — but the warning gives us a
            // footprint when transcribe() returns empty repeatedly.
            if !recognizer.isAvailable {
                NSLog("[AppleASREngine] WARNING: %@ recognizer reports !isAvailable. The %@ on-device asset may not be installed. Open System Settings → 键盘 → 听写 to add it.", hint, localeID)
            }
            built[hint] = recognizer
        }
        // Chinese is the required baseline: it's what VoiceService pre-checks and
        // the auto-detect fallback. Without it the engine can't realistically run.
        guard let chinese = built["Chinese"] else {
            NSLog("[AppleASREngine] zh-Hans on-device recognizer unavailable — engine init failed. Open System Settings → 键盘 → 听写 → 添加中文 (简体).")
            return nil
        }
        self.recognizers = built
        self.defaultRecognizer = chinese
    }

    func transcribe(audio: [Float], sampleRate: Int, language: String?, context: String?) -> String {
        // Each call gets its own temp file. Sharing a single path across calls (which
        // the previous implementation did) collides with concurrent invocations — the
        // streaming preview timer could overwrite the WAV mid-recognition or have its
        // `defer { remove }` delete the file out from under another in-flight task.
        // UUID per call eliminates the race entirely.
        let tempFileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vb_apple_asr_\(UUID().uuidString).wav")

        guard writeWAV(samples: audio, sampleRate: sampleRate, to: tempFileURL) else {
            NSLog("[AppleASREngine] Failed to write temporary WAV file at %@", tempFileURL.path)
            return ""
        }
        defer { try? FileManager.default.removeItem(at: tempFileURL) }

        // Pick the recognizer for the requested language. nil (auto-detect) or
        // an unmapped/uninstalled language falls back to Chinese — SFSpeechRecognizer
        // can't auto-detect, so a specific 会议语言 must be chosen for ja/en.
        let recognizer = recognizers[language ?? ""] ?? defaultRecognizer

        // If the recognizer flips to unavailable mid-session (asset still downloading,
        // device went to sleep, etc.) bail out with a logged reason instead of letting
        // the request hang for the full 30s timeout.
        guard recognizer.isAvailable else {
            NSLog("[AppleASREngine] Recognizer not available — skipping transcribe. Likely cause: on-device language asset missing for the selected 会议语言.")
            return ""
        }

        let request = SFSpeechURLRecognitionRequest(url: tempFileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        // Punctuation is inserted by the recognizer during recognition itself —
        // no extra pass, no added latency.
        request.addsPunctuation = true
        // Tell the recognizer this is free-form dictation (not a search query),
        // tuning it for continuous, sentence-length speech.
        request.taskHint = .dictation
        // Bias recognition toward the user's hotwords / proper nouns.
        if let context {
            let phrases = Self.contextualPhrases(from: context)
            if !phrases.isEmpty { request.contextualStrings = phrases }
        }

        // Run recognition with semaphore (blocking — must be called from background thread)
        let semaphore = DispatchSemaphore(value: 0)
        var resultText = ""

        var signaled = false
        recognizer.recognitionTask(with: request) { result, error in
            if let error {
                NSLog("[AppleASREngine] Recognition error: %@", error.localizedDescription)
            }
            if let result, result.isFinal {
                resultText = result.bestTranscription.formattedString
            }
            // Signal exactly once — callback may fire multiple times (partial + final + error)
            if result?.isFinal == true || error != nil {
                guard !signaled else { return }
                signaled = true
                semaphore.signal()
            }
        }

        let timeout = DispatchTime.now() + .seconds(30)
        if semaphore.wait(timeout: timeout) == .timedOut {
            NSLog("[AppleASREngine] Recognition timed out after 30s (audio length: %d samples / %.1fs)",
                  audio.count, Double(audio.count) / Double(max(sampleRate, 1)))
            return ""
        }

        return Self.ensureTerminalPunctuation(resultText, language: language)
    }

    /// Apple's recognizer punctuates *within* an utterance but routinely omits
    /// the final sentence-ending mark. Append one when the text doesn't already
    /// end with punctuation — a full-width 。 for CJK, a period for English.
    private static func ensureTerminalPunctuation(_ text: String, language: String?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        let terminators: Set<Character> = [
            "。", "！", "？", "…", ".", "!", "?",
            "，", ",", "、", "；", ";", "：", ":",
        ]
        guard !terminators.contains(last) else { return trimmed }
        return trimmed + (language == "English" ? "." : "。")
    }

    /// Extracts discrete hotword phrases from the descriptive context string
    /// that `VoiceService.buildHotwordContext` produces (format:
    /// "…可能出现以下专有名词：词A、词B、词C。"). `SFSpeechRecognizer.contextualStrings`
    /// expects individual vocabulary items rather than a sentence, so we pull
    /// the list back out. Best-effort — a parse miss only weakens biasing, it
    /// never breaks recognition.
    private static func contextualPhrases(from context: String) -> [String] {
        guard let marker = context.range(of: "专有名词：") else { return [] }
        let listSegment = context[marker.upperBound...]
            .split(separator: "。", maxSplits: 1).first.map(String.init) ?? ""
        return listSegment
            .split(separator: "、")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func unload() {
        // No-op — system manages SFSpeechRecognizer lifecycle
    }

    // MARK: - WAV File Writing

    /// Write Float32 audio samples as 16-bit PCM WAV file.
    private func writeWAV(samples: [Float], sampleRate: Int, to url: URL) -> Bool {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * Int(bitsPerSample / 8))
        let fileSize = 36 + dataSize

        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(littleEndian: fileSize)
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(littleEndian: UInt32(16))          // chunk size
        data.append(littleEndian: UInt16(1))           // PCM format
        data.append(littleEndian: numChannels)
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: byteRate)
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: bitsPerSample)

        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(littleEndian: dataSize)

        // Convert Float32 [-1.0, 1.0] to Int16
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16Value = Int16(clamped * Float(Int16.max))
            data.append(littleEndian: int16Value)
        }

        do {
            try data.write(to: url)
            return true
        } catch {
            NSLog("[AppleASREngine] Failed to write WAV: %@", error.localizedDescription)
            return false
        }
    }
}

// MARK: - Data Extension for Little-Endian Writing

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
