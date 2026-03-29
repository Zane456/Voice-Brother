import Foundation

/// Pure static text processing functions. No state.
enum TextProcessor {

    // MARK: - Filler words

    /// Common Chinese filler / hesitation words to remove.
    private static let fillers = ["呃", "额", "嗯", "啊啊", "哎"]

    // MARK: - Public API

    /// Full processing pipeline: optional filler removal, then replacement rules.
    static func process(text: String, removeFillers: Bool, rules: [ReplacementRule]) -> String {
        var result = text
        if removeFillers {
            result = Self.removeFillers(from: result)
        }
        result = Self.applyReplacements(to: result, rules: rules)
        return result
    }

    /// Remove filler words and clean up punctuation artifacts.
    ///
    /// Processing order:
    /// 1. Remove filler words: "呃", "额", "嗯", "啊啊", "哎"
    /// 2. Collapse duplicate commas (full-width and half-width): `[，,]{2,}` -> "，"
    /// 3. Collapse duplicate periods (full-width and half-width): `[。.]{2,}` -> "。"
    /// 4. Remove leading punctuation: `^[，,。.、]+`
    /// 5. Trim whitespace
    static func removeFillers(from text: String) -> String {
        var result = text

        // 1. Remove filler words
        for filler in fillers {
            result = result.replacingOccurrences(of: filler, with: "")
        }

        // 2. Collapse duplicate commas (full-width and half-width)
        result = replacePattern(result, pattern: "[，,]{2,}", with: "，")

        // 3. Collapse duplicate periods (full-width and half-width)
        result = replacePattern(result, pattern: "[。.]{2,}", with: "。")

        // 4. Remove leading punctuation (including Chinese dun-hao)
        result = replacePattern(result, pattern: "^[，,。.、]+", with: "")

        // 5. Trim whitespace
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Apply replacement rules in order. Each rule performs a literal string replacement.
    static func applyReplacements(to text: String, rules: [ReplacementRule]) -> String {
        var result = text
        for rule in rules {
            result = result.replacingOccurrences(of: rule.from, with: rule.to)
        }
        return result
    }

    // MARK: - Private helpers

    private static func replacePattern(_ text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        let result = regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: replacement
        )
        return result
    }
}
