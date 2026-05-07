import Foundation
import Qwen3Chat

/// Local LLM client for text post-processing (Layer 3).
/// Uses Qwen3-0.6B CoreML model for on-device inference.
final class LocalLLMClient: TextPolisher {

    private let model: Qwen3ChatModel
    private let userNotes: String

    /// Guard against concurrent polish calls — CoreML inference can't be cancelled,
    /// so overlapping calls would pile up GPU/CPU memory.
    private static let polishGuard = PolishGuard()

    final class PolishGuard: @unchecked Sendable {
        private var _busy = false
        private let lock = NSLock()

        func tryAcquire() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !_busy else { return false }
            _busy = true
            return true
        }

        func release() {
            lock.lock()
            _busy = false
            lock.unlock()
        }
    }

    init(model: Qwen3ChatModel, userNotes: String) {
        self.model = model
        self.userNotes = userNotes
    }

    // MARK: - TextPolisher

    func polish(_ text: String) async throws -> String {
        // Reject if another polish is already running to prevent task pile-up
        guard Self.polishGuard.tryAcquire() else {
            print("[LocalLLMClient] Skipping polish — previous inference still running")
            return text
        }
        defer { Self.polishGuard.release() }

        let systemPrompt = Self.buildSystemPrompt(userNotes: userNotes)

        let sampling = ChatSamplingConfig(
            temperature: 0.3,
            topK: 20,
            topP: 0.9,
            maxTokens: 128,
            repetitionPenalty: 1.1
        )

        // Run model.chat() on a GCD thread with timeout via continuation.
        // Cannot use Task cancellation — CoreML ignores it.
        let model = self.model
        let result: String = await withCheckedContinuation { continuation in
            var resumed = false
            let lock = NSLock()

            DispatchQueue.global(qos: .userInitiated).async {
                let output = try? model.chat(text, systemPrompt: systemPrompt, sampling: sampling)
                lock.lock()
                guard !resumed else { lock.unlock(); return }
                resumed = true
                lock.unlock()
                continuation.resume(returning: output ?? text)
            }

            // Timeout after 8 seconds — resume with original text
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                lock.lock()
                guard !resumed else { lock.unlock(); return }
                resumed = true
                lock.unlock()
                print("[LocalLLMClient] Timeout — inference exceeded 8s, returning original text")
                continuation.resume(returning: text)
            }
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? text : trimmed
    }
}
