import Foundation

/// Layer 1: Enhanced filler-word removal with context awareness.
///
/// Processing order:
/// 1. Remove repeated fillers first (e.g. "那个那个那个")
/// 2. Remove context-aware fillers ("那个" kept when demonstrative)
/// 3. Remove simple fillers (single-pass replacement)
/// 4. Clean up punctuation artifacts
/// 5. Trim whitespace
enum FillerRemover {

    // MARK: - Filler definitions

    /// Simple fillers — always removed.
    private static let simpleFillers: [String] = [
        // Hesitation sounds
        "呃", "额", "嗯", "啊啊", "哎", "嗯嗯", "诶",
        // Discourse markers (口头禅)
        "就是说", "怎么说呢", "你知道吧", "我觉得吧",
        "说实话", "老实说",
        // Common spoken padding
        "反正", "其实吧", "对吧", "是吧", "嘛",
    ]

    /// Fillers that need context check — may be legitimate words.
    /// "那个": demonstrative pronoun vs filler
    /// "就是": conjunction ("就是说") vs filler
    /// "然后": narrative connector vs filler
    /// "其实": adverb vs filler
    private static let contextFillers: [String] = [
        "那个", "就是", "然后", "其实",
    ]

    /// Characters that typically follow "那个" when used as a demonstrative pronoun.
    /// Measure words (量词) and common nouns.
    private static let demonstrativeFollowers: Set<Character> = {
        let chars = "人个位只条件块把张台架辆棵颗朵杯瓶碗盘份" +  // measure words
                    "事情东西地方时候问题方案项目方向" +           // common nouns
                    "男女老小大中新旧好坏"                        // adjectives before nouns
        return Set(chars)
    }()

    // MARK: - Public API

    /// Remove filler words from text with context awareness.
    static func process(_ text: String) -> String {
        var result = text

        // 0. Collapse ASR repetition loops first.
        //    Qwen3-ASR (and most autoregressive ASR) occasionally enter a
        //    decoding death spiral on noisy / ambiguous audio, emitting strings
        //    like "我我我我我..." or "啥？啥？啥？..." hundreds of times per
        //    segment. We squash those down to a single occurrence so the rest
        //    of the pipeline operates on sane-length text.
        result = collapseRepetitions(result)

        // 1. Remove repeated context fillers (e.g. "那个那个那个" is always filler)
        for filler in contextFillers {
            let repeated = filler + filler
            while result.contains(repeated) {
                result = result.replacingOccurrences(of: repeated, with: "")
            }
        }

        // 2. Context-aware removal
        result = removeContextFillers(from: result)

        // 3. Simple fillers — always remove (longer phrases first to avoid partial matches)
        let sorted = simpleFillers.sorted { $0.count > $1.count }
        for filler in sorted {
            result = result.replacingOccurrences(of: filler, with: "")
        }

        // 4. Clean punctuation artifacts
        result = cleanPunctuation(result)

        // 5. Trim
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Repetition collapse

    /// Collapse any 1–12-character substring that repeats 3+ times consecutively
    /// down to a single occurrence. Catches the full range of Qwen3-ASR loop
    /// patterns observed in real meetings:
    ///
    ///     "我我我我我"                  → "我"
    ///     "啥？啥？啥？啥？"             → "啥？"
    ///     "模型。模型。模型。"           → "模型。"
    ///     "啊，所以……啊，所以……啊，所以……" → "啊，所以……"
    ///     "西瓜的口感也挺不错的。西瓜的口感也挺不错的。西瓜的口感也挺不错的。" → "西瓜的口感也挺不错的。"
    ///     "そうそうそうそう"             → "そう"
    ///
    /// The non-greedy quantifier prefers the shortest repeating unit, which is
    /// what we want — "ababab" should become "ab" rather than "ababab"→"ababab".
    /// Patterns repeated only twice ("好好", "你好你好。") are intentionally
    /// preserved because they're often legitimate (reduplication, emphasis).
    private static func collapseRepetitions(_ text: String) -> String {
        replacePattern(text, pattern: #"(.{1,12}?)\1{2,}"#, with: "$1")
    }

    // MARK: - Context-aware removal

    /// Remove context-sensitive fillers based on surrounding text.
    private static func removeContextFillers(from text: String) -> String {
        var result = text

        // "那个" — keep only when followed by a demonstrative follower character
        result = removeNage(from: result)

        // "就是" — remove when at sentence start or after comma (filler usage)
        result = replacePattern(result, pattern: "(?:^|[，,。.！!？?；;])[\\s]*就是", with: "")

        // "然后" — remove when repeated or at sentence start as filler
        result = replacePattern(result, pattern: "(?:^|[，,])[\\s]*然后[，,]?[\\s]*然后", with: "")

        // "其实" — only remove "其实" at the very start (filler usage)
        result = replacePattern(result, pattern: "^其实[，,]?", with: "")

        return result
    }

    /// Context-aware removal of "那个".
    /// Keep when used as demonstrative (followed by noun/measure word),
    /// remove when used as filler (followed by punctuation, end of string, or another filler).
    private static func removeNage(from text: String) -> String {
        let target = "那个"
        var result = ""
        var index = text.startIndex

        while index < text.endIndex {
            if text[index...].hasPrefix(target) {
                let afterIndex = text.index(index, offsetBy: target.count, limitedBy: text.endIndex)
                if let afterIndex, afterIndex < text.endIndex {
                    let nextChar = text[afterIndex]
                    // Keep "那个" if followed by a demonstrative follower
                    if demonstrativeFollowers.contains(nextChar) {
                        result += target
                        index = afterIndex
                        continue
                    }
                }
                // Otherwise remove (filler usage) — skip past "那个"
                index = afterIndex ?? text.endIndex
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }

        return result
    }

    // MARK: - Punctuation cleanup

    /// Clean up punctuation artifacts left after filler removal.
    private static func cleanPunctuation(_ text: String) -> String {
        var result = text

        // Collapse duplicate commas
        result = replacePattern(result, pattern: "[，,]{2,}", with: "，")

        // Collapse duplicate periods
        result = replacePattern(result, pattern: "[。.]{2,}", with: "。")

        // Remove leading punctuation
        result = replacePattern(result, pattern: "^[，,。.、]+", with: "")

        // Remove comma right before period (e.g. "，。" → "。")
        result = replacePattern(result, pattern: "[，,][。.]", with: "。")

        // Remove trailing comma at end
        result = replacePattern(result, pattern: "[，,]+$", with: "")

        return result
    }

    // MARK: - Regex helper

    private static func replacePattern(_ text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}
