import AppKit
import Foundation
import UserNotifications

/// Analyzes diffs between injected and user-corrected text,
/// stores corrections, and auto-creates replacement rules when patterns emerge.
enum CorrectionAnalyzer {

    /// A single word/phrase substitution detected by diffing.
    struct Substitution {
        let from: String
        let to: String
    }

    /// Single replacement rules are short; longer diffs are almost always OCR drift.
    static let maxSubstitutionLength = 20

    /// Minimum char-level LCS similarity for a (from, to) pair to be plausible.
    /// 0.5 means at least half the characters must survive across the diff. Below
    /// this, from/to are effectively unrelated (OCR drift on an unrelated region,
    /// ASCII formula mis-read as CJK, etc.) and storing them pollutes the
    /// learning candidate list.
    static let minSimilarity = 0.5

    /// Cap on auto-learned hotwords. Without this, prolonged use lets the array
    /// grow unbounded, eventually bloating UserDefaults and slowing every
    /// transcription (the whole list is sent as model context). FIFO eviction
    /// drops the oldest entries when the cap is hit.
    static let maxHotwords = 200

    // MARK: - Diff

    /// Compare injected text with user's actual text and extract substitutions.
    /// Returns nil if texts are identical or too dissimilar (full rewrite).
    static func findSubstitutions(injected: String, actual: String) -> [Substitution]? {
        let injectedTrimmed = injected.trimmingCharacters(in: .whitespacesAndNewlines)
        let actualTrimmed = actual.trimmingCharacters(in: .whitespacesAndNewlines)

        // Identical — no correction
        if injectedTrimmed == actualTrimmed { return nil }

        // Check overall similarity
        let sim = FeedbackCollector.similarity(injectedTrimmed, actualTrimmed)

        // Too dissimilar — user rewrote everything, not a correction
        if sim < minSimilarity { return nil }

        // Word-level diff
        let injectedWords = tokenize(injectedTrimmed)
        let actualWords = tokenize(actualTrimmed)

        return extractSubstitutions(from: injectedWords, to: actualWords)
    }

    // MARK: - Learning

    /// Process a correction: store it and check if a rule should be auto-created.
    static func processCorrection(
        injected: String,
        actual: String,
        bundleID: String,
        correctionStore: CorrectionStore,
        configManager: ConfigManager
    ) async {
        // Privacy mode: suppress all smart-learning (no corrections recorded to disk).
        if await MainActor.run(body: { configManager.privacyMode }) { return }
        guard let substitutions = findSubstitutions(injected: injected, actual: actual),
              !substitutions.isEmpty else { return }

        for rawSub in substitutions {
            // Normalize whitespace so "CLaude " and "CLaude" don't count as
            // two separate candidates — OCR regularly adds trailing spaces.
            let from = rawSub.from.trimmingCharacters(in: .whitespacesAndNewlines)
            let to = rawSub.to.trimmingCharacters(in: .whitespacesAndNewlines)
            let sub = Substitution(from: from, to: to)

            // Skip trivial differences (single character, punctuation only)
            guard sub.from.count >= 2 || sub.to.count >= 2 else { continue }

            guard sub.from != sub.to else { continue }
            // Voice input context: if only casing differs ("Claude" vs "CLaude"),
            // the word is already right. Don't waste a learning slot on it.
            if sub.from.lowercased() == sub.to.lowercased() {
                NSLog("[CorrectionAnalyzer] REJECT case-only: '%@' → '%@'", sub.from, sub.to)
                continue
            }
            guard sub.from.count <= Self.maxSubstitutionLength,
                  sub.to.count <= Self.maxSubstitutionLength else { continue }
            guard FeedbackCollector.similarity(sub.from, sub.to) >= Self.minSimilarity else {
                NSLog("[CorrectionAnalyzer] REJECT low-sim: '%@' → '%@' (sim=%.2f)", sub.from, sub.to, FeedbackCollector.similarity(sub.from, sub.to))
                continue
            }
            // Length-ratio sanity: if one side is >2.5x the other, it's almost
            // always OCR picking up extra/missing text, not a word-level fix.
            let shorter = min(sub.from.count, sub.to.count)
            let longer = max(sub.from.count, sub.to.count)
            guard shorter > 0, Double(longer) / Double(shorter) <= 2.5 else {
                NSLog("[CorrectionAnalyzer] REJECT length-ratio: '%@'(%d) → '%@'(%d)", sub.from, sub.from.count, sub.to, sub.to.count)
                continue
            }

            // Check if this rule already exists
            let existingRules = configManager.replacements
            let alreadyExists = existingRules.contains { $0.from == sub.from && $0.to == sub.to }
            if alreadyExists { continue }

            // Store the correction
            let record = CorrectionRecord(
                injectedText: injected,
                correctedText: actual,
                diffFrom: sub.from,
                diffTo: sub.to,
                bundleID: bundleID
            )
            await correctionStore.insert(record)

            // Check if threshold is reached
            let count = await correctionStore.countMatching(from: sub.from, to: sub.to)
            let threshold = configManager.selfLearningThreshold

            if count >= threshold {
                // Auto-create replacement rule
                let newRule = ReplacementRule(from: sub.from, to: sub.to, source: .learned)
                await MainActor.run {
                    configManager.replacements.append(newRule)
                }
                await correctionStore.markAsApplied(from: sub.from, to: sub.to)

                // Notify user
                sendNotification(from: sub.from, to: sub.to)

                // Also add to hotwords if it looks like a proper noun
                if looksLikeProperNoun(sub.to) && !configManager.hotwords.contains(sub.to) {
                    await MainActor.run {
                        var updated = configManager.hotwords
                        // Enforce the cap with FIFO eviction. We trim BEFORE
                        // appending so the array is never persisted above the cap.
                        if updated.count >= Self.maxHotwords {
                            let overflow = updated.count - Self.maxHotwords + 1
                            updated.removeFirst(overflow)
                        }
                        updated.append(sub.to)
                        configManager.hotwords = updated
                    }
                    NSLog("[CorrectionAnalyzer] Auto-added hotword: %@ (total=%d)", sub.to, configManager.hotwords.count)
                }

                NSLog("[CorrectionAnalyzer] Auto-created rule: '%@' → '%@' (count=%d)", sub.from, sub.to, count)
            }
        }
    }

    // MARK: - Tokenization

    /// Tokenize text into words/phrases for diffing.
    /// For Chinese text, each character is a token; for English, words are tokens.
    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var currentWord = ""

        for char in text {
            if char.isASCII && (char.isLetter || char.isNumber) {
                currentWord.append(char)
            } else {
                if !currentWord.isEmpty {
                    tokens.append(currentWord)
                    currentWord = ""
                }
                if !char.isWhitespace {
                    tokens.append(String(char))
                }
            }
        }
        if !currentWord.isEmpty {
            tokens.append(currentWord)
        }
        return tokens
    }

    // MARK: - Word-Level Diff (LCS-based)

    /// Extract substitutions by finding the longest common subsequence of tokens,
    /// then grouping the differences.
    private static func extractSubstitutions(from source: [String], to target: [String]) -> [Substitution] {
        let m = source.count
        let n = target.count

        // LCS table
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if source[i - 1] == target[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack to find diff
        var i = m, j = n
        var sourceRemoved: [String] = []
        var targetAdded: [String] = []
        var substitutions: [Substitution] = []

        while i > 0 || j > 0 {
            if i > 0 && j > 0 && source[i - 1] == target[j - 1] {
                // Match — flush any accumulated diff
                if !sourceRemoved.isEmpty || !targetAdded.isEmpty {
                    let fromText = sourceRemoved.reversed().joined()
                    let toText = targetAdded.reversed().joined()
                    if !fromText.isEmpty && !toText.isEmpty {
                        substitutions.append(Substitution(from: fromText, to: toText))
                    }
                    sourceRemoved = []
                    targetAdded = []
                }
                i -= 1
                j -= 1
            } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                targetAdded.append(target[j - 1])
                j -= 1
            } else if i > 0 {
                sourceRemoved.append(source[i - 1])
                i -= 1
            }
        }

        // Flush remaining
        if !sourceRemoved.isEmpty || !targetAdded.isEmpty {
            let fromText = sourceRemoved.reversed().joined()
            let toText = targetAdded.reversed().joined()
            if !fromText.isEmpty && !toText.isEmpty {
                substitutions.append(Substitution(from: fromText, to: toText))
            }
        }

        return substitutions
    }

    // MARK: - Helpers

    private static func looksLikeProperNoun(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        // Starts with uppercase or contains mixed case (e.g., "Python", "JSON")
        return first.isUppercase || (text.contains(where: { $0.isUppercase }) && text.contains(where: { $0.isLowercase }))
    }

    private static func sendNotification(from: String, to: String) {
        let content = UNMutableNotificationContent()
        content.title = "Voice Bubble"
        content.body = "学到新规则: \"\(from)\" → \"\(to)\""
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
