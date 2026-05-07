import Foundation

/// Shared debug logger with automatic size rotation.
/// Writes to /tmp/vb_selflearn_debug.log with a 1MB cap.
enum DebugLog {
    private static let path = "/tmp/vb_selflearn_debug.log"
    private static let maxSize: UInt64 = 1_024_000 // 1 MB

    static func write(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let fm = FileManager.default

        // Rotate if file exceeds max size
        if fm.fileExists(atPath: path),
           let attrs = try? fm.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64,
           size > maxSize {
            try? fm.removeItem(atPath: path)
        }

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
}
