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
    private let recognizer: SFSpeechRecognizer

    /// Failable init. Returns nil for any reason the engine couldn't realistically
    /// run a Chinese on-device transcription right now.
    init?() {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-Hans")) else {
            NSLog("[AppleASREngine] Failed to create SFSpeechRecognizer for zh-Hans")
            return nil
        }
        guard recognizer.supportsOnDeviceRecognition else {
            NSLog("[AppleASREngine] On-device recognition not supported on this device")
            return nil
        }
        // `isAvailable` flips to false when the on-device language asset isn't present
        // (most common cause: user hasn't added Chinese in System Settings → Keyboard →
        // Dictation). We log a warning rather than failing init — the user might still
        // get useful results once the asset downloads in the background — but the warning
        // gives us a footprint when transcribe() returns empty repeatedly.
        if !recognizer.isAvailable {
            NSLog("[AppleASREngine] WARNING: recognizer reports !isAvailable. The zh-Hans on-device asset may not be installed. Open System Settings → 键盘 → 听写 → 添加中文 (简体).")
        }
        self.recognizer = recognizer
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

        // If the recognizer flips to unavailable mid-session (asset still downloading,
        // device went to sleep, etc.) bail out with a logged reason instead of letting
        // the request hang for the full 30s timeout.
        guard recognizer.isAvailable else {
            NSLog("[AppleASREngine] Recognizer not available — skipping transcribe. Likely cause: zh-Hans on-device language asset missing.")
            return ""
        }

        let request = SFSpeechURLRecognitionRequest(url: tempFileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

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

        // Note: `context` (hotwords) is intentionally unused — SFSpeechRecognizer has no
        // public API for biasing toward custom vocabulary. Users relying on hotwords
        // should switch to a Qwen3-ASR model.
        _ = context
        _ = language
        return resultText
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
