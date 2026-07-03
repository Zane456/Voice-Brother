import Foundation

// MARK: - AudioLevelTracker

/// Thread-safe holder for the latest mic & system-audio levels (0...1). The
/// overlay waveform is driven by whichever channel is louder, so it keeps moving
/// even when one channel is silent (e.g. the mic is occupied by another app).
/// Each setter returns the current max so callers can publish it directly.
final class AudioLevelTracker: @unchecked Sendable {
    private var _mic: Float = 0
    private var _sys: Float = 0
    private let lock = NSLock()

    func setMic(_ value: Float) -> Float {
        lock.withLock { _mic = value; return max(_mic, _sys) }
    }

    func setSystem(_ value: Float) -> Float {
        lock.withLock { _sys = value; return max(_mic, _sys) }
    }
}

// MARK: - ThreadSafeFlag

/// A simple thread-safe boolean flag using an NSLock.
/// Used to share recording state between @MainActor and nonisolated callbacks.
final class ThreadSafeFlag: @unchecked Sendable {
    private var _value = false
    private let lock = NSLock()

    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

// MARK: - AudioChunkBuffer

/// Thread-safe audio chunk buffer shared between @MainActor and nonisolated audio callbacks.
final class AudioChunkBuffer: @unchecked Sendable {
    private var _micChunks: [[Float]] = []
    private var _sysChunks: [[Float]] = []
    private let _lock = NSLock()

    /// Max chunks before dropping oldest. At 48kHz/4096-sample buffers ≈ 12 chunks/sec,
    /// 30 chunks ≈ 2.5 seconds — well above the 0.5s swap interval.
    private let maxChunks = 30

    var systemChunks: [[Float]] {
        get { _lock.withLock { _sysChunks } }
        set { _lock.withLock { _sysChunks = newValue } }
    }

    func appendMic(_ chunk: [Float]) {
        _lock.lock()
        _micChunks.append(chunk)
        if _micChunks.count > maxChunks {
            _micChunks.removeFirst(_micChunks.count - maxChunks)
        }
        _lock.unlock()
    }

    func appendSystem(_ chunk: [Float]) {
        _lock.lock()
        _sysChunks.append(chunk)
        if _sysChunks.count > maxChunks {
            _sysChunks.removeFirst(_sysChunks.count - maxChunks)
        }
        _lock.unlock()
    }

    func clearAll() {
        _lock.lock()
        _micChunks = []
        _sysChunks = []
        _lock.unlock()
    }

    func clearSystem() {
        _lock.lock()
        _sysChunks = []
        _lock.unlock()
    }

    /// Swap and return both mic and system chunks atomically.
    func swapAll() -> (mic: [[Float]], sys: [[Float]]) {
        _lock.lock()
        defer { _lock.unlock() }
        let mic = _micChunks
        let sys = _sysChunks
        _micChunks = []
        _sysChunks = []
        return (mic, sys)
    }
}
