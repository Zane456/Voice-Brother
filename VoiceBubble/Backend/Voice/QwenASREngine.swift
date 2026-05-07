import Foundation
import Qwen3ASR

/// Thin wrapper around Qwen3ASRModel conforming to ASREngineProtocol.
final class QwenASREngine: ASREngineProtocol {
    private let model: Qwen3ASRModel

    init(model: Qwen3ASRModel) {
        self.model = model
    }

    func transcribe(audio: [Float], sampleRate: Int, language: String?, context: String?) -> String {
        model.transcribe(
            audio: audio,
            sampleRate: sampleRate,
            language: language,
            context: context
        )
    }

    func unload() {
        model.unload()
    }
}
