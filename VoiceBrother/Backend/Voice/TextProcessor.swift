import Foundation

/// Text processing coordinator — chains processing layers into a pipeline.
///
/// Pipeline: Raw text → Layer 1 (filler removal) → Layer 2 (ITN)
///         → Replacement rules → Output
///         → Layer 3 (LLM polish) runs asynchronously in VoiceService after text injection state is restored.
///
/// Layer 1 (FillerRemover): Context-aware filler word removal
/// Layer 2 (ITNProcessor): Inverse Text Normalization (numbers, dates, math, etc.)
/// Layer 3: LLM polish — implemented by LLMClient (cloud)
enum TextProcessor {

    // MARK: - Public API

    /// Full processing pipeline: filler removal → ITN → replacement rules.
    /// Used by VoiceService.
    static func process(text: String, removeFillers: Bool, rules: [ReplacementRule]) -> String {
        var result = text

        // Layer 1: Filler removal
        if removeFillers {
            result = FillerRemover.process(result)
        }

        // Layer 2: Inverse Text Normalization
        result = ITNProcessor.process(result)

        // Replacement rules (user-defined find-and-replace)
        result = applyReplacements(to: result, rules: rules)

        return result
    }

    /// Filler-only pipeline. Used by MeetingService.
    /// Does NOT run ITN or replacement rules.
    static func removeFillers(from text: String) -> String {
        FillerRemover.process(text)
    }

    /// Cap repeated substrings, repeated sentences and identical single
    /// characters that the ASR sometimes loops on when fed long silences or
    /// monotone audio. Language-agnostic — operates on Unicode characters and
    /// generic punctuation, so it works for Chinese, Japanese and English.
    ///
    /// - Short repeated substrings (1–12 chars): if the same unit repeats 3+
    ///   times in a row, keep one copy.
    /// - Sentences (split on .。!！?？;； and newline): if the same sentence
    ///   repeats ≥ 3 times in a row, keep at most 2 copies.
    /// - Single-character runs (length-1 graphemes): if the same character
    ///   repeats ≥ 5 times in a row, collapse to 3 copies (preserves the
    ///   "我我我" emphasis pattern but kills "我我我我我我…我").
    static func collapseRepeats(in text: String) -> String {
        let loopCollapsed = collapseRepeatedSubstrings(text)
        let charCollapsed = collapseSingleCharRuns(loopCollapsed)
        return collapseSentenceRuns(charCollapsed)
    }

    private static func collapseRepeatedSubstrings(_ text: String) -> String {
        let pattern = #"(.{1,12}?)\1{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
    }

    private static func collapseSingleCharRuns(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var prev: Character? = nil
        var run = 0
        let maxRun = 3
        let triggerRun = 5
        for ch in text {
            if ch == prev {
                run += 1
            } else {
                prev = ch
                run = 1
            }
            // Always allow up to maxRun copies through; once run length passes
            // the trigger threshold, stop emitting further repeats.
            if run <= maxRun || run < triggerRun {
                out.append(ch)
            }
        }
        return out
    }

    private static func collapseSentenceRuns(_ text: String) -> String {
        // Sentence delimiters that work for CJK + Latin without depending on
        // language detection.
        let delimiters: Set<Character> = [".", "。", "!", "！", "?", "？", ";", "；", "\n"]
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if delimiters.contains(ch) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty { sentences.append(current) }

        var out: [String] = []
        var lastTrim: String = ""
        var run = 0
        for s in sentences {
            let trim = s.trimmingCharacters(in: .whitespaces)
            if !trim.isEmpty && trim == lastTrim {
                run += 1
                if run >= 3 { continue } // already kept 2, drop the rest
            } else {
                lastTrim = trim
                run = 1
            }
            out.append(s)
        }
        return out.joined()
    }

    /// Apply replacement rules in order. Each rule performs a literal string replacement.
    static func applyReplacements(to text: String, rules: [ReplacementRule]) -> String {
        var result = text
        for rule in rules {
            result = result.replacingOccurrences(of: rule.from, with: rule.to)
        }
        return result
    }
}

// MARK: - Layer 3 Protocol

/// LLM-based text polisher. Implemented by LLMClient (cloud).
protocol TextPolisher {
    func polish(_ text: String) async throws -> String
    func shouldPolish(_ text: String) -> Bool
}

extension TextPolisher {

    private static var defaultSystemPrompt: String {
        "你是语音转写文本优化助手。将语音转写文本优化为书面语，补充标点，修正口语表达。" +
        "保持原意，不添加内容。只输出优化后的文本，不要解释。"
    }

    /// Build system prompt. When user provides custom notes, they become the primary
    /// instruction and the "保持原意" constraint is removed to allow style transformation.
    static func buildSystemPrompt(userNotes: String) -> String {
        let notes = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.isEmpty {
            return defaultSystemPrompt
        }
        return "你是语音转写文本优化助手。对语音转写文本按以下要求进行处理，同时补充标点、修正口语表达。" +
            "只输出处理后的文本，不要解释。\n要求：" + notes
    }

    func shouldPolish(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4
    }
}
