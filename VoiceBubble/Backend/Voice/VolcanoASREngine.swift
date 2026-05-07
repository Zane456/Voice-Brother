import Foundation

/// Volcengine (火山引擎) Seed ASR 2.0 cloud engine conforming to ASREngineProtocol.
/// Uses WebSocket `bigmodel_async` endpoint with custom binary protocol.
///
/// Supports two modes:
/// 1. Batch: `transcribe()` opens WebSocket, sends all audio, waits for result (fallback)
/// 2. Streaming: `beginStreaming()` → `feedAudio()` during recording → `finishStreaming()` on release (fast)
final class VolcanoASREngine: ASREngineProtocol {

    private let appKey: String
    private let accessKey: String
    private let resourceId: String

    private static let endpoint =
        URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!

    // MARK: - Streaming State

    private var wsTask: URLSessionWebSocketTask?
    private var wsSession: URLSession?
    private var streamingResult = ""
    private var streamingPartial = ""
    private var streamingFinished = false
    private var streamingSemaphore = DispatchSemaphore(value: 0)
    private var streamingSignaled = false
    private let streamingLock = NSLock()
    /// Whether a streaming session is currently active.
    private(set) var isStreaming = false

    /// Callback for streaming preview updates (called with partial/confirmed text).
    var onStreamingUpdate: ((String) -> Void)?

    init(appKey: String, accessKey: String, resourceId: String) {
        self.appKey = appKey
        self.accessKey = accessKey
        self.resourceId = resourceId.isEmpty ? "volc.seedasr.sauc.duration" : resourceId
    }

    // MARK: - ASREngineProtocol (batch mode, fallback)

    func transcribe(audio: [Float], sampleRate: Int, language: String?, context: String?) -> String {
        // If streaming is active, finish it instead
        if isStreaming {
            return finishStreaming()
        }

        let pcmData = floatToPCM16(audio)
        guard !pcmData.isEmpty else { return "" }

        // Open connection, send everything, wait for result
        guard openWebSocket() else { return "" }
        // Volcano needs a concrete language — fall back to "Chinese" when the
        // caller didn't pin one. The Volcano endpoint isn't truly multilingual
        // the way Qwen3-ASR is, so "auto" via this engine is best-effort.
        sendConfig(sampleRate: sampleRate, language: language ?? "Chinese")
        startReceiveLoop()

        // Send audio in chunks (~200ms each)
        let chunkSize = sampleRate / 5 * 2
        var offset = 0
        while offset < pcmData.count {
            let end = min(offset + chunkSize, pcmData.count)
            let chunk = pcmData.subdata(in: offset..<end)
            let isLast = (end >= pcmData.count)
            sendAudioPacket(chunk, isLast: isLast)
            offset = end
        }

        // Wait for final result
        let timeout = DispatchTime.now() + .seconds(30)
        if streamingSemaphore.wait(timeout: timeout) == .timedOut {
            NSLog("[VolcanoASR] Batch transcription timed out")
        }

        let result = streamingResult
        closeWebSocket()
        return result
    }

    func unload() {
        cancelStreaming()
    }

    // MARK: - Streaming Mode

    /// Call when recording starts. Opens WebSocket and sends config.
    func beginStreaming(sampleRate: Int = 16000, language: String = "Chinese") {
        guard !isStreaming else { return }

        streamingLock.lock()
        streamingResult = ""
        streamingPartial = ""
        streamingFinished = false
        streamingSemaphore = DispatchSemaphore(value: 0)
        streamingSignaled = false
        streamingLock.unlock()

        guard openWebSocket() else { return }
        isStreaming = true
        sendConfig(sampleRate: sampleRate, language: language)
        startReceiveLoop()
        NSLog("[VolcanoASR] Streaming started")
    }

    /// Call from audio tap with PCM16 data. Thread-safe.
    func feedAudio(_ pcmData: Data) {
        guard isStreaming, !pcmData.isEmpty else { return }
        sendAudioPacket(pcmData, isLast: false)
    }

    /// Call when recording stops. Sends end signal and waits for final result.
    func finishStreaming() -> String {
        guard isStreaming else { return streamingResult }

        // Send empty last packet
        sendAudioPacket(Data(), isLast: true)
        NSLog("[VolcanoASR] Sent last packet, waiting for final result...")

        // Wait for final result (timeout 15s — server already has all audio)
        let timeout = DispatchTime.now() + .seconds(15)
        if streamingSemaphore.wait(timeout: timeout) == .timedOut {
            NSLog("[VolcanoASR] Final result timed out")
        }

        let result = streamingResult
        isStreaming = false
        closeWebSocket()
        NSLog("[VolcanoASR] Streaming finished: '%@'", result)
        return result
    }

    /// Cancel streaming without waiting for result.
    func cancelStreaming() {
        isStreaming = false
        closeWebSocket()
    }

    // MARK: - WebSocket Management

    private func openWebSocket() -> Bool {
        let connectId = UUID().uuidString
        var request = URLRequest(url: Self.endpoint)
        request.setValue(appKey, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(accessKey, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(connectId, forHTTPHeaderField: "X-Api-Connect-Id")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        task.resume()
        self.wsSession = session
        self.wsTask = task
        return true
    }

    private func closeWebSocket() {
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        wsSession?.invalidateAndCancel()
        wsSession = nil
    }

    private func sendConfig(sampleRate: Int, language: String) {
        let payload = VolcProtocol.buildClientRequest(sampleRate: sampleRate, language: language)
        let msg = VolcProtocol.encodeMessage(msgType: 0x01, flags: 0x00, serialization: 1, compression: 0, payload: payload)
        wsTask?.send(.data(msg)) { error in
            if let error { NSLog("[VolcanoASR] Config send error: %@", error.localizedDescription) }
        }
    }

    private func sendAudioPacket(_ data: Data, isLast: Bool) {
        let msg = VolcProtocol.encodeMessage(
            msgType: 0x02, flags: isLast ? 0x02 : 0x00,
            serialization: 0, compression: 0,
            payload: data
        )
        wsTask?.send(.data(msg)) { error in
            if let error { NSLog("[VolcanoASR] Audio send error: %@", error.localizedDescription) }
        }
    }

    private func startReceiveLoop() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .data(let data) = message, data.count > 4 {
                    let parsed = VolcProtocol.decodeResponse(data)
                    switch parsed {
                    case .transcript(let text, let isFinal):
                        self.streamingLock.lock()
                        if !text.isEmpty {
                            self.streamingResult = text
                        }
                        self.streamingLock.unlock()

                        // Notify preview update
                        if !text.isEmpty {
                            self.onStreamingUpdate?(text)
                        }

                        if isFinal {
                            self.signalOnce()
                            return
                        }
                    case .error(let code, let msg):
                        NSLog("[VolcanoASR] Error %d: %@", code, msg)
                        self.signalOnce()
                        return
                    case .sessionEnd:
                        self.signalOnce()
                        return
                    case .unknown:
                        break
                    }
                }
                self.startReceiveLoop() // Continue

            case .failure(let error):
                NSLog("[VolcanoASR] Receive error: %@", error.localizedDescription)
                self.signalOnce()
            }
        }
    }

    private func signalOnce() {
        streamingLock.lock()
        guard !streamingSignaled else {
            streamingLock.unlock()
            return
        }
        streamingSignaled = true
        streamingLock.unlock()
        streamingSemaphore.signal()
    }

    // MARK: - Audio Conversion

    /// Convert Float32 [-1,1] samples to Int16 PCM Data.
    func floatToPCM16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * Float(Int16.max))
            Swift.withUnsafeBytes(of: int16.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

// MARK: - Volcengine Binary Protocol

enum VolcProtocol {

    enum DecodedResponse {
        case transcript(String, isFinal: Bool)
        case error(Int, String)
        case sessionEnd
        case unknown
    }

    static func buildClientRequest(sampleRate: Int, language: String) -> Data {
        let langCode: String
        switch language.lowercased() {
        case "chinese", "zh", "zh-cn": langCode = "zh-CN"
        case "english", "en": langCode = "en-US"
        case "japanese", "ja": langCode = "ja-JP"
        default: langCode = "zh-CN"
        }

        let json: [String: Any] = [
            "user": ["uid": "voicebubble"],
            "audio": [
                "format": "pcm",
                "codec": "raw",
                "rate": sampleRate,
                "bits": 16,
                "channel": 1,
                "language": langCode
            ],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": true,
                "enable_punc": true,
                "show_utterances": true
            ]
        ]

        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    static func encodeMessage(msgType: UInt8, flags: UInt8, serialization: UInt8, compression: UInt8, payload: Data) -> Data {
        var data = Data(capacity: 8 + payload.count)
        data.append(contentsOf: [0x11, (msgType << 4) | (flags & 0x0F), (serialization << 4) | (compression & 0x0F), 0x00])
        var size = UInt32(payload.count).bigEndian
        Swift.withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    static func decodeResponse(_ data: Data) -> DecodedResponse {
        guard data.count >= 4 else { return .unknown }

        let msgType = (data[1] >> 4) & 0x0F
        let flags = data[1] & 0x0F
        let compression = data[2] & 0x0F

        if msgType == 0x0F {
            if data.count >= 12 {
                let code = Int(UInt32(bigEndian: data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }))
                let msgSize = Int(UInt32(bigEndian: data.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self) }))
                let msg = String(data: data.subdata(in: 12..<min(12 + msgSize, data.count)), encoding: .utf8) ?? ""
                return .error(code, msg)
            }
            return .sessionEnd
        }

        if msgType == 0x09, data.count >= 12 {
            let payloadSize = Int(UInt32(bigEndian: data.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self) }))
            guard data.count >= 12 + payloadSize else { return .unknown }
            var payload = data.subdata(in: 12..<(12 + payloadSize))

            if compression == 1 {
                payload = (try? (payload as NSData).decompressed(using: .zlib) as Data) ?? payload
            }

            if let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let result = json["result"] as? [String: Any] {
                let text = result["text"] as? String ?? ""
                let isFinal = (flags == 0x03)
                return .transcript(text, isFinal: isFinal)
            }
        }

        return .unknown
    }
}
