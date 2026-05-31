import Foundation

/// Shared debug logger with severity levels, size rotation, app-lifecycle
/// breadcrumbs, and best-effort crash capture.
///
/// Writes to `/tmp/vb_selflearn_debug.log` (1 MB cap, keeps one `.1` archive).
/// Parallel to the structured `ASRLogger`; both keep writing.
///
/// Why these breadcrumbs exist: without them the app never records its own
/// startup or shutdown, so you cannot tell a clean quit from a force-quit /
/// OOM-kill / crash by reading the log. The lifecycle dirty-flag + crash
/// handler close that gap — every abnormal exit now leaves a trail.
enum DebugLog {
    private static let path = "/tmp/vb_selflearn_debug.log"
    /// Dirty-flag: created on launch, deleted on clean exit. If it still exists
    /// at the next launch, the previous session did NOT exit cleanly.
    private static let markerPath = "/tmp/vb_running.marker"
    private static let maxSize: UInt64 = 1_024_000 // 1 MB

    enum Level: String { case info = "INFO", warn = "WARN", error = "ERROR" }

    /// One shared formatter — the old code allocated a new ISO8601 formatter on
    /// every line. Synchronized through `ioQueue` so it's never touched
    /// concurrently.
    private static let iso = ISO8601DateFormatter()
    /// Serializes file appends + rotation so concurrent callers (main actor,
    /// audio IO thread, meeting queues) can't interleave a half-written line or
    /// race the rotation rename.
    private static let ioQueue = DispatchQueue(label: "com.voicebrother.debuglog")

    // MARK: - Write API

    /// Backward-compatible entry point — every existing caller stays INFO.
    static func write(_ message: String) { log(.info, message) }
    static func warn(_ message: String) { log(.warn, message) }
    static func error(_ message: String) { log(.error, message) }

    static func log(_ level: Level, _ message: String) {
        ioQueue.async {
            let line = "[\(iso.string(from: Date()))] [\(level.rawValue)] \(message)\n"
            appendLine(line)
        }
    }

    /// Must be called on `ioQueue`.
    private static func appendLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        rotateIfNeeded()
        if fm.fileExists(atPath: path) {
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            }
        } else {
            fm.createFile(atPath: path, contents: data)
        }
    }

    /// Rotate by archiving to `.1` instead of deleting — the old code dropped
    /// the entire 1 MB, so a crash right after a rotation lost all context.
    /// Must be called on `ioQueue`.
    private static func rotateIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64,
              size > maxSize else { return }
        let archive = path + ".1"
        try? fm.removeItem(atPath: archive)
        try? fm.moveItem(atPath: path, toPath: archive)
    }

    // MARK: - Lifecycle breadcrumbs

    /// Record app start. Call once, as early as possible in the GUI launch path
    /// (NOT on the headless `--retranscribe` path — that exits via `exit()` and
    /// would leave a stale marker that falsely flags the next real launch).
    static func logLaunch() {
        let fm = FileManager.default
        if fm.fileExists(atPath: markerPath) {
            error("[Lifecycle] previous session ended ABNORMALLY — no clean exit recorded "
                + "(force-quit / OOM-kill / power loss, or a crash the handler couldn't catch)")
        }
        fm.createFile(atPath: markerPath, contents: Data())
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        write("[Lifecycle] launch v\(v) (build \(b)) pid=\(ProcessInfo.processInfo.processIdentifier)")
    }

    /// Record a clean shutdown and clear the dirty-flag. Call from
    /// `applicationWillTerminate` — it fires on ⌘Q / normal quit but NOT on
    /// SIGKILL (force-quit, OOM), so the marker survives exactly the abnormal
    /// cases.
    static func logCleanExit() {
        write("[Lifecycle] clean exit")
        try? FileManager.default.removeItem(atPath: markerPath)
    }

    // MARK: - Crash capture

    private static var handlersInstalled = false
    /// Prebuilt per-signal breadcrumbs. Rendered once at install time so the
    /// signal handler itself does zero formatting (async-signal-safe path).
    private static var signalMessages: [Int32: [CChar]] = [:]

    /// Install uncaught-exception + fatal-signal handlers. Idempotent. Call as
    /// early as possible (before any model load) so a crash during startup is
    /// still recorded. Re-raises with the default handler afterward, so macOS
    /// still produces its normal `.ips` crash report.
    static func installCrashHandlers() {
        guard !handlersInstalled else { return }
        handlersInstalled = true

        NSSetUncaughtExceptionHandler { ex in
            let stack = ex.callStackSymbols.prefix(25).joined(separator: "\n")
            DebugLog.error("[Crash] NSException \(ex.name.rawValue): \(ex.reason ?? "(no reason)")\n\(stack)")
        }

        let sigs: [(Int32, String)] = [
            (SIGABRT, "SIGABRT"), (SIGSEGV, "SIGSEGV"), (SIGILL, "SIGILL"),
            (SIGTRAP, "SIGTRAP"), (SIGBUS, "SIGBUS"), (SIGFPE, "SIGFPE"),
        ]
        for (sig, name) in sigs {
            let msg = "[CRASH] fatal signal \(name) (\(sig)) — process aborting; "
                + "see prior lines + the OS crash report for the stack\n"
            signalMessages[sig] = msg.utf8CString.map { $0 }
            signal(sig) { s in DebugLog.handleFatalSignal(s) }
        }
    }

    /// Signal-handler context: only async-signal-safe work — write a prebuilt
    /// buffer via raw POSIX `write`, then restore the default disposition and
    /// re-raise so the normal crash pipeline still runs. No Foundation, no
    /// allocation, no string formatting here.
    private static func handleFatalSignal(_ sig: Int32) {
        if let bytes = signalMessages[sig] {
            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            if fd >= 0 {
                bytes.withUnsafeBufferPointer { buf in
                    if let base = buf.baseAddress {
                        // Darwin.write — disambiguate from DebugLog.write(_:).
                        _ = Darwin.write(fd, base, strlen(base))
                    }
                }
                close(fd)
            }
        }
        signal(sig, SIG_DFL)
        raise(sig)
    }
}
