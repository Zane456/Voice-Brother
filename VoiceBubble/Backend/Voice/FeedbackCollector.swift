import AppKit
import Foundation
import ScreenCaptureKit
import Vision

/// Captures window screenshots and performs OCR to extract text for correction comparison.
enum FeedbackCollector {

    /// Information captured at the moment of text injection.
    struct PendingFeedback {
        let injectedText: String
        let windowID: CGWindowID
        let bundleID: String
        let timestamp: Date
    }

    // MARK: - Public API

    /// Captures the window screenshot, performs OCR, and returns the recognized text.
    /// Call this ~300ms after Enter press to allow UI to update.
    static func collectText(for pending: PendingFeedback) async -> String? {
        // Layer 1 — never OCR a known password manager. Their windows often hold
        // plaintext credentials and we don't want them in the correction store
        // OR in any debug log.
        if sensitiveBundleIDs.contains(pending.bundleID) {
            fcLog("SKIP: bundleID \(pending.bundleID) is on the sensitive denylist")
            return nil
        }

        // Wait for UI to update after Enter/send
        try? await Task.sleep(for: .milliseconds(300))

        // Screenshot the specific window via ScreenCaptureKit
        guard let image = await captureWindow(pending.windowID) else {
            fcLog("FAIL: captureWindow returned nil for windowID=\(pending.windowID)")
            return nil
        }
        fcLog("Screenshot OK: \(image.width)x\(image.height) for windowID=\(pending.windowID)")

        // OCR the screenshot
        let ocrText = await recognizeText(in: image)
        // Length-only log — never write OCR contents until after the sensitive scan.
        fcLog("OCR raw text (\(ocrText.count) chars)")
        guard !ocrText.isEmpty else {
            fcLog("FAIL: OCR returned empty text")
            return nil
        }

        // Layer 2 — bail if the OCR caught anything that looks like a secret,
        // anywhere in the visible window. A correction record ships the diff
        // (and sometimes the surrounding text) into the SQLite store, and we
        // don't want a leaked API key sitting on disk.
        if containsSensitive(ocrText) {
            fcLog("SKIP: OCR contains a sensitive token pattern")
            return nil
        }

        // Find the region in OCR output that best matches the injected text
        let extracted = extractRelevantText(from: ocrText, matching: pending.injectedText)
        fcLog("Extracted: \(extracted ?? "nil") (matching: \(pending.injectedText))")
        return extracted
    }

    // MARK: - Sensitive content guards

    /// Bundle identifiers of known password managers and other apps where any
    /// on-screen text is presumed sensitive. We never OCR these.
    private static let sensitiveBundleIDs: Set<String> = [
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword4",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.lastpass.LastPass",
        "com.dashlane.dashlanephonefinal",
        "com.dashlane.Dashlane",
        "io.enpass.mac",
        "com.apple.keychainaccess",
    ]

    /// Patterns that strongly suggest a secret is visible on screen. Compiled
    /// once and reused — `try!` is intentional: these are static literals and a
    /// failure here is a programmer bug, not a runtime condition.
    private static let sensitivePatterns: [NSRegularExpression] = [
        // Bearer/JWT (eyJ... base64)
        try! NSRegularExpression(pattern: #"\beyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_.-]{10,}"#),
        // OpenAI / Anthropic / Slack / GitHub / Stripe style prefixed keys
        try! NSRegularExpression(pattern: #"\b(sk|pk|rk|ak|xoxp|xoxb|xoxa|ghp|gho|ghu|ghs|github_pat)[-_][A-Za-z0-9_-]{20,}"#),
        // SSH / PGP private key markers
        try! NSRegularExpression(pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        // Long contiguous hex (API tokens, hashes, secrets)
        try! NSRegularExpression(pattern: #"\b[a-fA-F0-9]{40,}\b"#),
        // 16-digit credit card number (with optional spaces / dashes)
        try! NSRegularExpression(pattern: #"\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b"#),
        // AWS access key ID
        try! NSRegularExpression(pattern: #"\bAKIA[0-9A-Z]{16}\b"#),
    ]

    private static func containsSensitive(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in sensitivePatterns {
            if pattern.firstMatch(in: text, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Window Screenshot (ScreenCaptureKit)

    private static func captureWindow(_ windowID: CGWindowID) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                fcLog("SCK: window \(windowID) not found in shareable content")
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            config.width = Int(scWindow.frame.width) * 2  // Retina
            config.height = Int(scWindow.frame.height) * 2
            config.capturesAudio = false
            config.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return image
        } catch {
            fcLog("SCK capture error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Get the frontmost window's CGWindowID and bundle identifier.
    static func captureFrontmostWindowInfo() -> (windowID: CGWindowID, bundleID: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleID = app.bundleIdentifier ?? "unknown"

        // Get window list for the frontmost app
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // Find the largest window belonging to the frontmost app (avoids picking sub-windows like input bars)
        let pid = app.processIdentifier
        var bestWindowID: CGWindowID = 0
        var bestArea: CGFloat = 0

        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == pid,
                  let windowID = window[kCGWindowNumber as String] as? CGWindowID,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bounds["Width"], let h = bounds["Height"]
            else { continue }
            let area = w * h
            if area > bestArea {
                bestArea = area
                bestWindowID = windowID
            }
        }

        guard bestWindowID != 0 else { return nil }
        return (bestWindowID, bundleID)
    }

    // MARK: - OCR

    private static func recognizeText(in image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard let observations = request.results as? [VNRecognizedTextObservation], error == nil else {
                    continuation.resume(returning: "")
                    return
                }

                // Collect all recognized text, sorted by vertical position (top to bottom)
                let sorted = observations.sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
                let lines = sorted.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }

            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                fcLog("OCR failed: \(error.localizedDescription)")
                continuation.resume(returning: "")
            }
        }
    }

    // MARK: - Text Extraction

    /// Find the region in OCR output that best matches the injected text.
    /// Uses longest common subsequence to handle partial matches.
    private static func extractRelevantText(from ocrText: String, matching injected: String) -> String? {
        let ocrLines = ocrText.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !ocrLines.isEmpty else { return nil }

        // Try exact substring match first
        let normalizedOCR = ocrText.replacingOccurrences(of: "\n", with: "")
        if normalizedOCR.contains(injected) {
            return injected // text was not modified
        }

        // Find the line(s) most similar to the injected text
        var bestMatch = ""
        var bestScore: Double = 0

        // Try single lines
        for line in ocrLines {
            let score = similarity(line, injected)
            if score > bestScore {
                bestScore = score
                bestMatch = line
            }
        }

        // Try consecutive line pairs/triples for multi-line matches
        for i in 0..<ocrLines.count {
            let maxLen = min(3, ocrLines.count - i)
            guard maxLen >= 2 else { continue }
            for length in 2...maxLen {
                let combined = ocrLines[i..<(i + length)].joined()
                let score = similarity(combined, injected)
                if score > bestScore {
                    bestScore = score
                    bestMatch = combined
                }
            }
        }

        // Require at least 30% similarity to consider it a match
        guard bestScore >= 0.3 else { return nil }

        return bestMatch
    }

    /// Compute similarity between two strings using longest common subsequence ratio.
    static func similarity(_ a: String, _ b: String) -> Double {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count
        guard m > 0, n > 0 else { return 0 }

        // LCS dynamic programming
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if aChars[i - 1] == bChars[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        let lcsLength = dp[m][n]
        return Double(lcsLength) / Double(max(m, n))
    }

    // MARK: - Debug

    private static func fcLog(_ message: String) {
        DebugLog.write("[FeedbackCollector] \(message)")
    }
}
