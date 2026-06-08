import Foundation

/// Self-learning correction subsystem — Voice Brother's local equivalent of
/// 豆包输入法's "一次纠正，长期精准".
///
/// When the user corrects a past transcription in the history tab, the change
/// is diffed into a minimal find→replace pair (`CorrectionDiff`) and saved as a
/// `.learned` `ReplacementRule`. Every future transcription then has that rule
/// applied automatically — merged after the user's manual rules — so the same
/// mistake is not made twice.
///
/// ## Isolation guarantees
/// The rest of the app must keep working even if this whole subsystem breaks:
///   • Learned rules live in their OWN store (`learning/learned_rules.json`),
///     never mixed into `AppConfig.replacements` (the user's manual rules).
///   • `activeRules` is the only thing the recording path reads. If loading
///     fails it is simply empty, and transcription behaves exactly as before.
///   • All disk I/O is delegated to `LearningJournal` on a background queue
///     with best-effort error handling — nothing here can throw into a caller.
@MainActor
final class CorrectionLearningEngine {

    static let shared = CorrectionLearningEngine()

    private let journal = LearningJournal()
    private weak var configManager: ConfigManager?

    /// Rules promoted from user corrections. Read by `VoiceService` and merged
    /// after the user's manual rules when processing each transcription.
    private(set) var activeRules: [ReplacementRule] = []

    /// Common spoken words / fillers / pronouns that recur in almost every
    /// utterance. An auto-learned rule whose `from` is one of these fires on
    /// nearly every transcription — the exact "好了 → 我的ext" failure: the user
    /// rewrote one sentence's content, the engine generalised it into a global
    /// replace. We never promote an edit on these into a rule. Manual rules are
    /// NOT affected — this gates auto-learning only. Length alone can't catch
    /// these (legit number rules like 一百/二十 are the same 2–4 chars), so an
    /// explicit stoplist is the real defense.
    private static let nonLearnableTerms: Set<String> = [
        // 应答 / 语气词
        "好", "好的", "好了", "好吧", "好啊", "好嘞", "行", "行了", "可以", "没问题",
        "没事", "嗯", "嗯嗯", "嗯哼", "哦", "噢", "呃", "啊", "呀", "哈", "哈哈",
        "对", "对的", "对对", "对吧", "是", "是的", "是吧", "是啊", "OK", "ok", "Ok",
        // 指代 / 连接 / 口头禅
        "那", "那个", "这", "这个", "就是", "就", "然后", "还有", "而且", "但是",
        "不过", "所以", "因为", "如果", "这样", "那样", "这样子", "那样子",
        "现在", "怎么", "什么", "为什么", "怎么样",
        // 人称
        "我", "你", "他", "她", "它", "我们", "你们", "他们", "她们",
        "我的", "你的", "他的", "她的", "大家",
    ]

    private init() {}

    /// Edge punctuation stripped before matching the stoplist — CJK sentence
    /// marks + full-width space only. Deliberately NOT the whole
    /// `.punctuationCharacters` set: that also strips ASCII `! ? . _ #` etc., so
    /// a legit ASCII correction like "OK!" would normalize to "OK" and get
    /// wrongly skipped as a common word.
    private static let edgePunctuation = CharacterSet(charactersIn: "。，、！？；：…—　")

    /// Strip surrounding whitespace and CJK sentence punctuation so "好了。"
    /// still matches the "好了" stoplist entry.
    private func normalizedTerm(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(Self.edgePunctuation))
    }

    /// Wire up at app launch. Loads rules learned in previous sessions.
    func configure(configManager: ConfigManager) {
        self.configManager = configManager
        self.activeRules = journal.loadRules()
        migrateOrphanedLearnedRules()
        journal.log("ENGINE  启动 — 已加载 \(activeRules.count) 条已学规则")
    }

    /// One-time self-heal: evict `.learned` rules that an older app version
    /// persisted into `AppConfig.replacements` (the manual store) instead of the
    /// isolated learned store. Such orphans keep firing via the recording path
    /// but `forget()` / REVERT can never reach them — and worse, they sit in
    /// `configManager.replacements`, so `manualConflicts` matches every new
    /// correction against them and silently blocks all future learning.
    ///
    /// Fix: MOVE them into `activeRules` (the isolated store), deduped by `from`.
    /// They keep working — VoiceService fires `replacements + activeRules`, so
    /// total behaviour is unchanged — but become manageable again. Idempotent:
    /// once replacements holds no `.learned` rule, this is a no-op.
    private func migrateOrphanedLearnedRules() {
        guard let configManager else { return }
        let orphans = configManager.replacements.filter { $0.source == .learned }
        guard !orphans.isEmpty else { return }

        var existingFroms = Set(activeRules.map { $0.from })
        var moved = 0
        for orphan in orphans where !existingFroms.contains(orphan.from) {
            activeRules.append(orphan)
            existingFroms.insert(orphan.from)
            moved += 1
        }
        configManager.replacements.removeAll { $0.source == .learned }
        journal.persistRules(activeRules)
        journal.log("MIGRATE 从手动规则迁出 \(orphans.count) 条孤儿 learned 规则（实际并入 \(moved) 条，去重后共 \(activeRules.count) 条）")
    }

    /// Outcome of a `learn` call, so the UI can show a brief confirmation.
    struct LearnResult {
        let learned: Bool
        let from: String
        let to: String
        let message: String   // empty when nothing user-visible happened
    }

    /// Observe a user correction of a past transcription. Never throws —
    /// a failure simply means nothing was learned.
    @discardableResult
    func learn(originalText: String, correctedText: String, bundleID: String = "") -> LearnResult {
        // Record every correction attempt that reaches the engine, so the
        // journal always shows whether learning succeeded — and if not, why.
        journal.log("EDIT    收到编辑 \"\(originalText.prefix(40))\" → \"\(correctedText.prefix(40))\"")

        // Pre-migration history record with no raw ASR text — there is nothing
        // reliable to diff against, so this edit cannot be learned.
        guard !originalText.isEmpty else {
            journal.log("SKIP    该记录无原始 ASR 文本（旧记录），无法学习")
            return LearnResult(learned: false, from: "", to: "", message: "")
        }

        guard let pair = CorrectionDiff.extract(original: originalText, corrected: correctedText) else {
            journal.log("SKIP    编辑无法提炼成规则（无改动 / 纯增删 / 整句重写 / 跨度过短或过长）")
            return LearnResult(learned: false, from: "", to: "", message: "")
        }

        // Keep the raw capture for auditing / future tuning. Happens even when
        // we ultimately refuse to promote the diff into a rule — the audit log
        // is more useful with the full event stream.
        journal.appendCorrection(CorrectionRecord(
            injectedText: originalText, correctedText: correctedText,
            diffFrom: pair.from, diffTo: pair.to, bundleID: bundleID
        ))
        journal.bump(capturedDelta: 1)

        // REVERT signal — user is undoing a previously learned rule by
        // correcting in the opposite direction (A→B was learned; now B→A is
        // diffed). Forget the stale rule instead of stacking a counter-rule
        // that would just oscillate against it.
        if let revertIdx = activeRules.firstIndex(where: { $0.from == pair.to && $0.to == pair.from }) {
            let stale = activeRules.remove(at: revertIdx)
            journal.persistRules(activeRules)
            journal.log("REVERT  撤销已学规则 \"\(stale.from)\" → \"\(stale.to)\"（用户反向编辑）")
            return LearnResult(learned: false, from: pair.from, to: pair.to,
                               message: "已撤销之前学的：\(stale.from) → \(stale.to)")
        }

        // Refuse to learn when the changed span is just a common spoken word /
        // filler / pronoun. Such a rule would fire on nearly every utterance —
        // the "好了 → 我的ext" failure mode. Gates auto-learning only; manual
        // rules can still target these words deliberately.
        // MUST run AFTER the REVERT check above: a stale rule whose `to` is a
        // common word is undone by reverse-editing (pair.from == that word). If
        // this gate ran first it would short-circuit and the rule could never
        // be undone.
        if Self.nonLearnableTerms.contains(normalizedTerm(pair.from)) {
            journal.log("SKIP    常用口语词 \"\(pair.from)\" → \"\(pair.to)\"，不自动学（避免每句误触发）")
            return LearnResult(learned: false, from: pair.from, to: pair.to,
                               message: "「\(pair.from)」是常用词，已跳过自动学习")
        }

        // Refuse pairs that overlap a manual rule's `from` or `to`. If a
        // learned rule's `from` appears anywhere in a manual rule's input or
        // output (or vice versa), a single transcription could trip both rules
        // and the second pass would silently rewrite the first pass's output.
        if let manual = configManager?.replacements,
           let conflict = manual.first(where: { manualConflicts(pair: pair, with: $0) }) {
            journal.log("SKIP    pair \"\(pair.from)\" → \"\(pair.to)\" 与手动规则 \"\(conflict.from)\" → \"\(conflict.to)\" 重叠")
            return LearnResult(learned: false, from: pair.from, to: pair.to, message: "")
        }

        // Same guard, but against OTHER learned rules — without it, rule A's
        // output can be re-rewritten by a later learned rule B (好的→码投→Modo
        // chaining), since VoiceService applies all learned rules in sequence.
        // Exclude the same-`from` rule: that's the update/dedup case handled
        // below, and it always "overlaps" itself.
        if let conflict = activeRules.first(where: {
            $0.from != pair.from && manualConflicts(pair: pair, with: $0)
        }) {
            journal.log("SKIP    pair \"\(pair.from)\" → \"\(pair.to)\" 与已学规则 \"\(conflict.from)\" → \"\(conflict.to)\" 重叠")
            return LearnResult(learned: false, from: pair.from, to: pair.to, message: "")
        }

        // Already learned this source term?
        if let idx = activeRules.firstIndex(where: { $0.from == pair.from }) {
            if activeRules[idx].to == pair.to {
                journal.log("SKIP    已学规则 \"\(pair.from)\" → \"\(pair.to)\"，无需重复")
                return LearnResult(learned: false, from: pair.from, to: pair.to,
                                   message: "这条纠正已经学过了")
            }
            activeRules[idx].to = pair.to
            journal.persistRules(activeRules)
            journal.bump(learnedDelta: 1)
            journal.log("UPDATE  规则 \"\(pair.from)\" → \"\(pair.to)\"（覆盖旧目标）")
            return LearnResult(learned: true, from: pair.from, to: pair.to,
                               message: "已更新：\(pair.from) → \(pair.to)")
        }

        activeRules.append(ReplacementRule(from: pair.from, to: pair.to, source: .learned))
        journal.persistRules(activeRules)
        journal.bump(learnedDelta: 1)
        journal.log("LEARN   规则 \"\(pair.from)\" → \"\(pair.to)\"（共 \(activeRules.count) 条）")
        return LearnResult(learned: true, from: pair.from, to: pair.to,
                           message: "已学会：\(pair.from) → \(pair.to)，下次自动套用")
    }

    /// True when `pair` overlaps a manual rule's input or output in a way that
    /// would let the two fire on the same transcription and rewrite each
    /// other's results. We compare substrings in both directions because rule
    /// application is plain literal `String.replacingOccurrences`.
    private func manualConflicts(pair: CorrectionDiff.Pair, with manual: ReplacementRule) -> Bool {
        guard !manual.from.isEmpty else { return false }
        // Same source term — manual already covers it (also catches exact dup).
        if pair.from.contains(manual.from) || manual.from.contains(pair.from) { return true }
        // Learned rule would fire on manual's output.
        if !manual.to.isEmpty && manual.to.contains(pair.from) { return true }
        // Manual rule would fire on learned's output.
        if pair.to.contains(manual.from) { return true }
        return false
    }

    /// Tally how many learned rules would fire on a fresh ASR result, for the
    /// effectiveness ledger. Call with the RAW transcription text (pre-processing).
    func noteTranscription(rawText: String) {
        guard !activeRules.isEmpty, !rawText.isEmpty else { return }
        let hits = activeRules.reduce(0) { $0 + (rawText.contains($1.from) ? 1 : 0) }
        guard hits > 0 else { return }
        journal.bump(hitsDelta: hits)
        journal.log("HIT     本次转写命中 \(hits) 条已学规则")
    }

    /// Drop a learned rule (e.g. a bad capture the user wants undone).
    func forget(from: String) {
        activeRules.removeAll { $0.from == from }
        journal.persistRules(activeRules)
        journal.log("FORGET  删除已学规则 \"\(from)\"")
    }

    // MARK: - Inspection (UI / debugging)

    var learnedRuleCount: Int { activeRules.count }
    var storageDirectory: String { journal.directoryPath }
    func recentStats() -> [DayStat] { journal.loadStats() }
    func recentCorrections() -> [CorrectionRecord] { journal.loadCorrections() }
}
