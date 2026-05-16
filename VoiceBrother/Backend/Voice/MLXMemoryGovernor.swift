import Foundation
import MLX

/// Bounds MLX's GPU buffer cache so it doesn't accumulate dozens of GB across
/// long-running transcription sessions.
///
/// MLX recycles buffers between operations to avoid alloc churn, but on a
/// 32 GB+ Mac the default cache limit equals the memory limit (effectively
/// unbounded). Each transcribe call has variable audio length → variable
/// hidden-state and KV-cache buffer sizes. Variable sizes can't be reused
/// from the pool, so old buffers stay parked in cache and process RSS
/// climbs into the tens of GB after a few hundred recordings.
///
/// We cap the cache at a value small enough to keep RSS reasonable but
/// large enough to avoid hot-path allocation overhead. Anything above the
/// cap is reclaimed by MLX on the next allocation. We also clear explicitly
/// after every transcription so reuse never has to wait for the next alloc.
enum MLXMemoryGovernor {

    /// Cache size cap. 256 MB is plenty to absorb the steady-state buffer
    /// churn of a single Qwen3-ASR generation pass (the largest single
    /// intermediate is the KV-cache for ~448 tokens of decoder context,
    /// well under 100 MB) while keeping the high-water mark predictable.
    private static let cacheLimitBytes = 256 * 1024 * 1024

    /// Whether `configure()` has run. Idempotent — safe to call multiple times.
    private static var configured = false

    /// Set cache + memory limits. Call once at app launch, before any model
    /// is loaded so the limit is in place when the first allocations happen.
    static func configure() {
        guard !configured else { return }
        configured = true
        MLX.Memory.cacheLimit = cacheLimitBytes
        // Clear any cache that the framework allocated during initial
        // import-time setup so we start from a clean baseline.
        MLX.Memory.clearCache()
    }

    /// Force MLX to drop all cached buffers right now. Call after each
    /// transcribe so variable-length intermediates don't accumulate.
    /// Safe to call from any thread — `clearCache` is internally serialized.
    static func reclaim() {
        MLX.Memory.clearCache()
    }

    /// Diagnostic: current MLX memory state. Useful for logging during
    /// investigation without enabling Instruments.
    static func snapshotDescription() -> String {
        let snap = MLX.Memory.snapshot()
        let mb = { (bytes: Int) in String(format: "%.1f MB", Double(bytes) / 1_048_576.0) }
        return "MLX active=\(mb(snap.activeMemory)) cache=\(mb(snap.cacheMemory)) peak=\(mb(snap.peakMemory))"
    }
}
