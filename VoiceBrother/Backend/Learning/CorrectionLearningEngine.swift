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

    private init() {}

    /// Wire up at app launch. Loads rules learned in previous sessions.
    func configure(configManager: ConfigManager) {
        self.configManager = configManager
        self.activeRules = journal.loadRules()
        journal.log("ENGINE  启动 — 已加载 \(activeRules.count) 条已学规则")
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

        // Refuse pairs that overlap a manual rule's `from` or `to`. If a
        // learned rule's `from` appears anywhere in a manual rule's input or
        // output (or vice versa), a single transcription could trip both rules
        // and the second pass would silently rewrite the first pass's output.
        if let manual = configManager?.replacements,
           let conflict = manual.first(where: { manualConflicts(pair: pair, with: $0) }) {
            journal.log("SKIP    pair \"\(pair.from)\" → \"\(pair.to)\" 与手动规则 \"\(conflict.from)\" → \"\(conflict.to)\" 重叠")
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
