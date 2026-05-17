import Foundation
import Speech

/// Apple SFSpeechRecognizer wrapper conforming to ASREngineProtocol.
/// On-device only recognition. Failable init — returns nil only when the device
/// can't run on-device recognition for any of Chinese/English/Japanese at all.
/// A missing *individual* language asset does not fail init; callers check the
/// selected language with `isLanguageReady(_:)` to give a precise error.
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
    /// across languages, so auto-detect meetings fall back to this — Chinese
    /// when available, otherwise the first of English/Japanese that is.
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
        // The engine needs at least one usable on-device recognizer. Chinese is
        // the preferred default (it's the auto-detect fallback in transcribe()),
        // but it is NOT a hard requirement: an English/Japanese-only user must
        // still be able to run. VoiceService's per-language preflight surfaces a
        // precise error if the *selected* language specifically is missing —
        // returning nil here would mislabel that as "device unsupported".
        guard let fallback = built["Chinese"] ?? built["English"] ?? built["Japanese"] else {
            NSLog("[AppleASREngine] No on-device recognizer available — engine init failed. Open System Settings → 键盘 → 听写 to add a dictation language.")
            return nil
        }
        self.recognizers = built
        self.defaultRecognizer = fallback
    }

    /// Whether the on-device asset for the given `asrLanguageHint`
    /// ("Chinese"/"English"/"Japanese") is installed and ready to transcribe.
    /// A missing key means the recognizer couldn't be created on this device at
    /// all; a present-but-`!isAvailable` recognizer means the language asset
    /// hasn't been added in System Settings → Keyboard → Dictation.
    func isLanguageReady(_ hint: String) -> Bool {
        recognizers[hint]?.isAvailable ?? false
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
        // an unmapped language falls back to `defaultRecognizer` — SFSpeechRecognizer
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

    mutating func appendUTF8(_ string: String) {
        append(contentsOf: string.utf8)
    }
}

/// OpenAI Whisper cloud ASR wrapper. Unlike VolcanoASREngine, this is a batch
/// upload path: record locally, encode a WAV, then POST multipart/form-data to
/// `/audio/transcriptions`.
final class OpenAIWhisperASREngine: ASREngineProtocol {
    private let apiKey: String
    private let baseURL: String
    private let model: String
    private let timeout: TimeInterval

    init(apiKey: String, baseURL: String, model: String, timeout: TimeInterval = 45) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.timeout = timeout
    }

    func transcribe(audio: [Float], sampleRate: Int, language: String?, context: String?) -> String {
        guard !apiKey.isEmpty else {
            NSLog("[OpenAIWhisperASR] Missing API key")
            return ""
        }
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/audio/transcriptions") else {
            NSLog("[OpenAIWhisperASR] Invalid Base URL: %@", baseURL)
            return ""
        }
        guard let wavData = Self.makeWAVData(samples: audio, sampleRate: sampleRate), !wavData.isEmpty else {
            NSLog("[OpenAIWhisperASR] Failed to encode WAV")
            return ""
        }

        let boundary = "VoiceBrotherBoundary-\(UUID().uuidString)"
        var fields: [String: String] = [
            "model": model.isEmpty ? CloudASRProvider.openaiWhisper.defaultModel : model,
            "response_format": "json",
            "temperature": "0"
        ]
        if let languageCode = Self.openAILanguageCode(for: language) {
            fields["language"] = languageCode
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            fields: fields,
            fileField: "file",
            filename: "voice-brother.wav",
            contentType: "audio/wav",
            fileData: wavData,
            boundary: boundary
        )

        let semaphore = DispatchSemaphore(value: 0)
        var resultText = ""
        var requestError: String?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                requestError = error.localizedDescription
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                requestError = "Invalid HTTP response"
                return
            }
            guard let data else {
                requestError = "Empty response body"
                return
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "Unknown error"
                requestError = "HTTP \(httpResponse.statusCode): \(body)"
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                requestError = "Unable to parse transcription response"
                return
            }
            resultText = text
        }
        task.resume()

        if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            NSLog("[OpenAIWhisperASR] Request timed out")
            return ""
        }
        if let requestError {
            NSLog("[OpenAIWhisperASR] %@", requestError)
        }
        return resultText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() {
        // No persistent model state.
    }

    private static func openAILanguageCode(for language: String?) -> String? {
        switch language {
        case "Chinese": return "zh"
        case "English": return "en"
        case "Japanese": return "ja"
        default: return nil
        }
    }

    private static func multipartBody(
        fields: [String: String],
        fileField: String,
        filename: String,
        contentType: String,
        fileData: Data,
        boundary: String
    ) -> Data {
        var body = Data()
        for (name, value) in fields {
            body.appendUTF8("--\(boundary)\r\n")
            body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendUTF8("\(value)\r\n")
        }
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\n")
        body.appendUTF8("Content-Type: \(contentType)\r\n\r\n")
        body.append(fileData)
        body.appendUTF8("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func makeWAVData(samples: [Float], sampleRate: Int) -> Data? {
        guard sampleRate > 0 else { return nil }

        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * Int(bitsPerSample / 8))
        let fileSize = 36 + dataSize

        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))
        data.appendUTF8("RIFF")
        data.append(littleEndian: fileSize)
        data.appendUTF8("WAVE")
        data.appendUTF8("fmt ")
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: numChannels)
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: byteRate)
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: bitsPerSample)
        data.appendUTF8("data")
        data.append(littleEndian: dataSize)

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            data.append(littleEndian: Int16(clamped * Float(Int16.max)))
        }
        return data
    }
}
