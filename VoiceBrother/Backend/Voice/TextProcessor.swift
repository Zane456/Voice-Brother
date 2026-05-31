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
    /// - Single-character runs (length-1 graphemes): keep at most 3 copies of
    ///   any consecutive repeat (preserves the "我我我" emphasis pattern but
    ///   kills "我我我我我我…我").
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
        for ch in text {
            if ch == prev {
                run += 1
            } else {
                prev = ch
                run = 1
            }
            // Keep at most maxRun copies of any character run; drop the rest.
            // Preserves the "我我我" emphasis pattern, kills "我我我我我…" runaways.
            if run <= maxRun {
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

/// 上下文打包给 LLM polish。所有字段都可选——空值时 prompt 自动省略对应段，
/// 不会留空行。设计参考豆包 Seed-ASR 2.0 的 context_data 思路：场景 + 最近
/// 输入 + 常用词，让 LLM 看上下文做同音字消歧和大小写规范。
struct PolishContext {
    /// 用户自定义说明（VocabularyTab → 局部 LLM 备注）。空字符串时走默认 prompt。
    var userNotes: String = ""
    /// 录音瞬间前台 app 名（如 Xcode、微信）。
    var appContext: String? = nil
    /// 最近 N 条历史转写文本，**仅作话题参考**——可能含识别错误，不应被 LLM 当 ground truth 信任。
    var recentHistory: [String] = []
    /// 用户在 VocabularyTab 配置的热词。
    var hotwords: [String] = []
    /// 自学习引擎沉淀的高频替换目标词。
    var learnedTerms: [String] = []
    /// 内置英文术语词典——用于纠正中英混输大小写。
    var techLexicon: [String] = TechLexicon.defaults

    static let empty = PolishContext()
}

extension TextPolisher {

    /// 默认 prompt——用户未给任何 hint 时用。短小，避免反喧宾夺主。
    private static var defaultSystemPromptBare: String {
        "你是语音转写文本优化助手。将语音转写文本优化为书面语，补充标点，修正口语表达。" +
        "保持原意，不添加内容。只输出优化后的文本，不要解释。"
    }

    /// 旧签名：仅 userNotes，兼容老调用方。新代码请用 `buildSystemPrompt(context:)`。
    static func buildSystemPrompt(userNotes: String) -> String {
        buildSystemPrompt(context: PolishContext(userNotes: userNotes))
    }

    /// 完整版 prompt——把 PolishContext 渲染成多段提示。
    ///
    /// 分支策略（重要）：
    /// • `userNotes` 为空 → 用豆包式 5 项任务作主指令。这是默认/无预设场景，
    ///   享受升级（同音字、断句、删口吃、中英大小写）。
    /// • `userNotes` 非空 → 完全照旧逻辑：notes 作主指令，不附加豆包任务说明。
    ///   兼容用户的「应用预设」（邮件风格 / 翻译 / 改成正式语等场景化预设）——
    ///   旧版注释明示「保持原意」约束被去除以允许 style transformation，新版必须保留这个语义。
    ///
    /// 不论哪个分支，热词 / 自学习词 / 英文术语词典 / 应用场景 都作为「参考事实」附加——
    /// 这些是用户已确认的领域知识，无论 polish 目标是什么都有助于减少错字。
    /// 最近历史本身可能含 ASR 错字，prompt 已经标注「话题参考」让 LLM 不要强化。
    static func buildSystemPrompt(context ctx: PolishContext) -> String {
        let notes = ctx.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)

        // ─── 主指令段 ───
        let mainInstruction: String
        if notes.isEmpty {
            // 默认豆包式 5 项任务——只在用户未填 notes 时生效。
            mainInstruction = """
            你是语音转写文本优化助手。对一段中文 / 中英混输的语音转写做后处理。

            任务：
            1. 根据上下文修正同音错字（如「直到/知道」「在意/再议」「码头/马头」）。
            2. 中英混输大小写规范：英文专有名词保持官方拼写（参考「英文术语」段）。
            3. 补全标点、按语义断句；过长口语句分成短句。
            4. 删除无意义的口吃、重复、语气词，保留口语自然度，不书面化过度。
            5. 不改变原意，不补充用户没说的内容。
            只输出修正后的文本，不要解释、不要前后缀。
            """
        } else {
            // 完全照旧逻辑——尊重「应用预设」可能想做风格转换 / 翻译 / 改语气。
            // 此处不附加「不改变原意」约束，与旧版行为一致。
            mainInstruction = "你是语音转写文本优化助手。对语音转写文本按以下要求进行处理，同时补充标点、修正口语表达。"
                + "只输出处理后的文本，不要解释。\n要求：" + notes
        }

        // ─── 参考段（无论 notes 是否存在都附加，作为"事实补充"）───
        var refs: [String] = []

        if let app = ctx.appContext, !app.isEmpty {
            refs.append("【当前应用场景】\(app)")
        }

        if !ctx.recentHistory.isEmpty {
            // 最近输入做"话题参考"——注明可能含错以免 LLM 把过往错字当事实强化。
            let lines = ctx.recentHistory
                .prefix(5)
                .enumerated()
                .map { "  \($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            refs.append("""
            【最近输入（仅作话题参考，可能含 ASR 错字，不要当事实信任）】
            \(lines)
            """)
        }

        // 热词 + 自学习词合并去重——都是用户常用 / 已确认的领域词。
        var userVocab = Array(NSOrderedSet(array: ctx.hotwords + ctx.learnedTerms)) as? [String] ?? []
        userVocab = userVocab.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !userVocab.isEmpty {
            refs.append("【用户常用词 / 专有名词】\(userVocab.joined(separator: "、"))")
        }

        if !ctx.techLexicon.isEmpty {
            refs.append("【英文术语（保持大小写）】\(ctx.techLexicon.joined(separator: ", "))")
        }

        // 没有任何参考段，且没有 notes → 退到最简旧版 prompt（保持完全向后兼容）。
        if refs.isEmpty && notes.isEmpty {
            return defaultSystemPromptBare
        }

        return ([mainInstruction] + refs).joined(separator: "\n\n")
    }

    func shouldPolish(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4
    }
}
