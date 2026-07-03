import Foundation

/// Thread-safe store for the raw audio chunks captured during a voice recording.
/// The audio tap callback (a CoreAudio IO thread) appends here while the main
/// actor swaps/reads; every access goes through `audioLock`.
final class VoiceAudioChunkStore {

    /// Audio buffer protected by a lock for thread-safe access from audio tap callback.
    private var _audioChunks: [Data] = []
    private let audioLock = NSLock()

    /// Thread-safe swap of audioChunks, returning current contents.
    func swapAudioChunks() -> [Data] {
        audioLock.lock()
        defer { audioLock.unlock() }
        let chunks = _audioChunks
        _audioChunks = []
        return chunks
    }

    /// Thread-safe append to audioChunks.
    func appendAudioChunk(_ data: Data) {
        audioLock.lock()
        _audioChunks.append(data)
        audioLock.unlock()
    }

    /// Thread-safe clear audioChunks.
    func clearAudioChunks() {
        audioLock.lock()
        _audioChunks = []
        audioLock.unlock()
    }

    /// Thread-safe copy of audioChunks (without clearing).
    func readAudioChunks() -> [Data] {
        audioLock.lock()
        defer { audioLock.unlock() }
        return Array(_audioChunks)
    }

    /// Merge audio chunk Data into Float array, skipping initial samples to avoid key press bleed.
    /// For very short recordings, scales the skip down proportionally instead of skipping
    /// the entire buffer (which would leave the leading key-press noise in place).
    func mergeAudioSamples(from chunks: [Data]) -> [Float] {
        var allSamples: [Float] = []
        for chunk in chunks {
            let count = chunk.count / MemoryLayout<Float>.size
            chunk.withUnsafeBytes { rawBufferPointer in
                if let baseAddress = rawBufferPointer.baseAddress {
                    let floatPtr = baseAddress.assumingMemoryBound(to: Float.self)
                    allSamples.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: count))
                }
            }
        }
        // Skip the leading key-press noise, but protect short utterances. Below
        // 1.0s of audio total, skip nothing at all — single-syllable words like
        // "好"/"嗯"/"对"/"OK" can land in the 0.15–0.6s range and we want every
        // sample reaching ASR. Above 1.0s we strip the full 100ms, which still
        // leaves ≥0.9s of real speech for the model.
        let minRetainSamples = 16_000  // 1.0s @ 16kHz
        let maxSkip = max(0, allSamples.count - minRetainSamples)
        let actualSkip = min(skipSamples, maxSkip)
        if actualSkip > 0 {
            allSamples = Array(allSamples.dropFirst(actualSkip))
        }
        return allSamples
    }

    /// Number of audio samples to skip at the start of recording — purely to trim
    /// the leading "key press click" noise that bleeds into the audio tap.
    ///
    /// Built-in mic: 400ms is enough to mask the held-key sound and any analog
    /// click captured by a sensitive built-in array.
    ///
    /// Bluetooth: 0. The SCO warm-up window (which used to be where leading
    /// garbage came from) is now handled by the `hasReceivedRealAudio` gate in
    /// the audio tap — anything before the first non-silent buffer is discarded
    /// at capture time. A *post-tap* skip on top of that just chops off real
    /// speech the user already said. This was the bug behind "前几个字识别不上".
    var skipSamples: Int {
        // Built-in: 100ms (was 400ms — too aggressive; fn / modifier triggers don't
        // make a click sound, so 400ms was eating real speech from the user's first
        // 1–2 characters). Bluetooth: 0 (gated by hasReceivedRealAudio elsewhere).
        AudioEngineController.isCurrentInputBluetooth() ? 0 : 1_600  // 0s vs 0.1s @ 16kHz
    }
}
