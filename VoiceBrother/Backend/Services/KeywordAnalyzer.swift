import Foundation
import NaturalLanguage

/// Stateless keyword frequency analyzer for voice transcription history.
///
/// Tags mixed-language text (Chinese / Japanese / English) with the system
/// `NLTagger` and keeps only nouns — verbs, prepositions, particles and other
/// function words are dropped so the word cloud surfaces topical keywords.
/// Stopwords / single characters / pure numbers are filtered out, and the
/// most frequently used words are returned ranked by count.
enum KeywordAnalyzer {

    /// A ranked keyword. `weight` is a 0...1 value used to drive font size
    /// and color depth in the word cloud — 1.0 is the most-used word.
    struct Keyword: Identifiable, Hashable, Sendable {
        let word: String
        let count: Int
        let weight: Double
        var id: String { word }
    }

    /// Analyze a corpus of transcription texts and return the top keywords.
    /// - Parameters:
    ///   - texts: raw transcription strings.
    ///   - topCount: maximum number of keywords to return.
    /// - Returns: keywords sorted by frequency, descending. Words appearing
    ///   fewer than twice are discarded.
    static func analyze(texts: [String], topCount: Int = 40) -> [Keyword] {
        var counts: [String: Int] = [:]
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .omitOther]

        for text in texts where !text.isEmpty {
            tagger.string = text
            tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                                 unit: .word,
                                 scheme: .lexicalClass,
                                 options: options) { tag, range in
                // Keep only nouns. `.otherWord` is kept too: it's where the
                // tagger files proper / brand / foreign nouns (e.g. skill,
                // claude, agent) it can't classify into a known language.
                guard let tag, tag == .noun || tag == .otherWord else { return true }
                if let normalized = normalize(String(text[range])) {
                    counts[normalized, default: 0] += 1
                }
                return true
            }
        }

        let ranked = counts
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(topCount)

        guard let maxCount = ranked.first?.value,
              let minCount = ranked.last?.value else { return [] }

        let maxRoot = sqrt(Double(maxCount))
        let minRoot = sqrt(Double(minCount))

        return ranked.map { entry in
            let weight: Double
            if maxRoot == minRoot {
                weight = 1.0
            } else {
                // sqrt scaling lifts low-frequency words so they stay legible.
                weight = (sqrt(Double(entry.value)) - minRoot) / (maxRoot - minRoot)
            }
            return Keyword(word: entry.key, count: entry.value, weight: weight)
        }
    }

    // MARK: - Token filtering

    /// Normalizes a raw token, returning `nil` if it should be discarded.
    private static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.unicodeScalars.contains(where: isCJK) {
            // CJK / Japanese word: drop single characters and stopwords.
            guard trimmed.count >= 2, !chineseStopwords.contains(trimmed) else { return nil }
            return trimmed
        } else {
            // Latin word: drop short tokens, pure numbers, and stopwords.
            let lower = trimmed.lowercased()
            guard lower.count >= 2,
                  lower.contains(where: { $0.isLetter }),
                  !englishStopwords.contains(lower) else { return nil }
            return lower
        }
    }

    /// True for Han ideographs (shared by Chinese hanzi & Japanese kanji) and
    /// the Japanese kana scripts — these all use character-based length rules.
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x4E00...0x9FFF).contains(v)   // CJK Unified Ideographs
            || (0x3400...0x4DBF).contains(v)   // CJK Extension A
            || (0x3040...0x309F).contains(v)   // Hiragana
            || (0x30A0...0x30FF).contains(v)   // Katakana
    }

    /// Common multi-character Chinese words carrying no topical meaning.
    /// Single characters are already removed by the length check.
    private static let chineseStopwords: Set<String> = [
        "这个", "那个", "什么", "怎么", "没有", "一个", "一下", "我们", "你们",
        "他们", "她们", "因为", "所以", "但是", "如果", "就是", "可以", "这样",
        "那样", "这些", "那些", "然后", "还有", "这种", "那种", "知道", "觉得",
        "这里", "那里", "现在", "时候", "已经", "不是", "应该", "其实", "这么",
        "那么", "这是", "或者", "而且", "不过", "只是", "本来", "一直", "可能",
        "需要", "的话", "之类", "等等", "怎样", "为什么", "是不是", "有点",
        "一点", "这边", "那边", "目前", "包括", "对于", "通过", "以及", "其中",
        "比如", "一些", "一种", "一样", "这次", "下面", "上面", "东西"
    ]

    /// Common English function words.
    private static let englishStopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "is", "are", "was", "were", "be",
        "been", "being", "to", "of", "in", "on", "at", "for", "with", "as", "it",
        "its", "this", "that", "these", "those", "i", "you", "he", "she", "we",
        "they", "my", "your", "our", "his", "her", "their", "me", "him", "them",
        "us", "do", "does", "did", "have", "has", "had", "will", "would", "can",
        "could", "should", "not", "no", "yes", "so", "if", "then", "than",
        "there", "here", "what", "which", "who", "when", "where", "how", "all",
        "any", "some", "just", "very", "too", "also", "from", "by", "up", "out",
        "about", "into", "over", "after", "before"
    ]
}
