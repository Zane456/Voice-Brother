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
    /// these (they share the 2–4 char length of ordinary terms), so an explicit
    /// stoplist is the real defense. Pure number conversions (一百/二十) are
    /// gated separately by `isITNNumberRule`, not this stoplist.
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

    /// Chinese-number characters vs ITN output characters. A pair where `from`
    /// is purely the former and `to` purely the latter (二十→20、一百→100、
    /// 百分之一→1%、等于零→=0) is ITNProcessor's job — it converts numbers
    /// context-aware (skips ordinals like 第二十, branches by date/time/currency).
    /// A context-free learned string rule is redundant and misfires inside larger
    /// numbers/ordinals, so we never learn it and evict any that slipped in.
    /// Pairs containing a letter (V一→V1) are NOT pure-number, so stay learnable.
    /// Kept in sync with `_is_itn_number_rule` in
    /// extensions/dynamic-hotwords/update_hotwords.py.
    private static let cnNumberChars = Set("零〇一二三四五六七八九十百千万亿两点分之等于负")
    private static let itnOutputChars = Set("0123456789.%=/+-*:")
    private func isITNNumberRule(from: String, to: String) -> Bool {
        guard !from.isEmpty, !to.isEmpty else { return false }
        return from.allSatisfy { Self.cnNumberChars.contains($0) }
            && to.allSatisfy { Self.itnOutputChars.contains($0) }
    }

    /// Wire up at app launch. Loads rules learned in previous sessions.
    func configure(configManager: ConfigManager) {
        self.configManager = configManager
        self.activeRules = journal.loadRules()
        migrateOrphanedLearnedRules()
        evictNonLearnableRules()
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

    /// 全部官方拼写：热词 ∪ 手动规则的 `to` ∪ 已学规则的 `to`。
    /// `HotwordSnapper` 拿它当吸附目标——要把 `G L M` 还原成 `GLM`，
    /// 目标词必须在场，不管是谁引入的。
    func officialSpellings() -> Set<String> {
        var set = Set(activeRules.map { $0.to })
        set.formUnion(externalTargets())
        set.remove("")
        return set
    }

    /// `PhoneticGate` ch3 的准入白名单：热词 ∪ 手动规则的 `to`。**不含已学规则的 `to`**。
    ///
    /// 已学规则的 `to` 必须排除，否则 ch3 退化成「这条规则的目标词在词表里，
    /// 因为这条规则在」——每条 ASCII 目标的规则都自我批准。实测：`好了 → 我的ext`
    /// 在 `evictNonLearnableRules()` 里走到 ch3，`targets.contains("我的ext")` 为真
    /// （它是自己的 `to`），`isMostlyASCIIAlnum` 为真（3/5 ≥ 0.5）→ 发音闸放行，
    /// 清扫失效。白名单只认**外部**来源，规则不能自证。
    ///
    /// 注意不能改写成 `officialSpellings().subtracting([rule.to])`：`cloud → Claude`
    /// 的 `Claude` 同时由热词表提供，按字符串抹掉会把这条合法规则误杀。
    /// 排除的是「已学规则这一来源」，不是某个字符串。
    func admissionWhitelist() -> Set<String> {
        var set = externalTargets()
        set.remove("")
        return set
    }

    /// 外部来源的目标词：热词 ∪ **手动**规则的 `to`。
    /// 排掉 `.learned` 是为了防夜间脚本注入、尚未被 `migrateOrphanedLearnedRules`
    /// 搬走的规则混进白名单——那同样是自证。
    private func externalTargets() -> Set<String> {
        guard let configManager else { return [] }
        var set = Set(configManager.hotwords)
        set.formUnion(configManager.replacements.filter { $0.source != .learned }.map { $0.to })
        return set
    }

    /// Sweep resident learned rules whose `from` is a common spoken word.
    /// `learn()` refuses to CREATE such rules, but that gate only covers the
    /// in-app path — the dynamic-hotwords launchd script writes learned rules
    /// straight into UserDefaults, and `migrateOrphanedLearnedRules` then
    /// imports them here unchecked. That bypass is how "好了 → 我的ext" kept
    /// resurrecting nightly after every cleanup. Runs each launch; no-op when
    /// nothing matches.
    ///
    /// 同时用 `PhoneticGate` 兜底清扫发音不相近的规则。Python 侧的
    /// `phonetic_gate()` 用 pypinyin 取多音字读音交集，比这里宽松（两端对
    /// 「朴」的读音判断就不一致：pypinyin 给 piao，CFStringTransform 给 pu）。
    /// 宽→严的方向是安全的：脚本多捞，这里终审。
    private func evictNonLearnableRules() {
        let targets = admissionWhitelist()
        let bad = activeRules.filter {
            Self.nonLearnableTerms.contains(normalizedTerm($0.from))
                || isITNNumberRule(from: normalizedTerm($0.from), to: normalizedTerm($0.to))
                || !PhoneticGate.allows($0.from, $0.to, knownTargets: targets)
        }
        guard !bad.isEmpty else { return }
        let badIDs = Set(bad.map { $0.id })
        activeRules.removeAll { badIDs.contains($0.id) }
        journal.persistRules(activeRules)
        for rule in bad {
            journal.log("EVICT   清除规则 \"\(rule.from)\" → \"\(rule.to)\"（黑名单/数字ITN/发音闸 兜底，外部注入）")
        }
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

        // Refuse pure Chinese-number → Arabic/percent/equation conversions —
        // ITNProcessor owns these (context-aware: skips 第二十 ordinals, branches
        // by date/time/currency). A flat string rule is redundant and misfires.
        // MUST run AFTER the REVERT check, same as the stoplist gate above, so an
        // existing number rule can still be undone by a reverse edit.
        if isITNNumberRule(from: normalizedTerm(pair.from), to: normalizedTerm(pair.to)) {
            journal.log("SKIP    数字 ITN 规则 \"\(pair.from)\" → \"\(pair.to)\"，交给 ITNProcessor（避免冗余/序数误触发）")
            return LearnResult(learned: false, from: pair.from, to: pair.to,
                               message: "数字转换交给内置规则处理，已跳过")
        }

        // Phonetic admission gate — 豆包 `AsrUserCorrectDict::Add` 的对应物。
        // 一次编辑会被提升成 GLOBAL 替换规则，以后每句都跑。改写内容
        // （内容→论文）和纠听错字（质朴→智谱）在字符层面无法区分，只有发音能。
        // MUST 在 REVERT 检测之后：反向编辑撤销旧规则时两侧本就不同音，
        // 提前拦截会让已学的坏规则永远撤不掉。
        if !PhoneticGate.allows(pair.from, pair.to, knownTargets: admissionWhitelist()) {
            journal.log("SKIP    发音不相近 \"\(pair.from)\" → \"\(pair.to)\"，不自动学（PhoneticGate 拒绝）")
            return LearnResult(learned: false, from: pair.from, to: pair.to,
                               message: "「\(pair.from)」与「\(pair.to)」发音差异过大，已跳过")
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
    /// Logs WHICH rules fired and bumps their per-rule counters — aggregate
    /// counts alone can't tell a workhorse rule from a dead one (the 637 hits
    /// that turned out to be all ITN junk rules got past exactly that gap).
    func noteTranscription(rawText: String) {
        guard !activeRules.isEmpty, !rawText.isEmpty else { return }
        let fired = activeRules.filter { rawText.contains($0.from) }
        guard !fired.isEmpty else { return }
        journal.bump(hitsDelta: fired.count)
        journal.bumpRuleHits(fired.map { $0.from })
        let detail = fired.map { "\"\($0.from)→\($0.to)\"" }.joined(separator: " ")
        journal.log("HIT     本次转写命中 \(fired.count) 条已学规则: \(detail)")
    }

    /// Tally which configured hotwords actually appear in a fresh ASR result.
    /// The nightly miner picks hotwords by frequency gap, with no evidence of
    /// whether priming pays off — this ledger supplies that evidence, so
    /// zero-hit words can be spotted (nightly report) and pruned. ASCII
    /// case-insensitive. No log line: most transcripts hit several words and
    /// per-line logging would drown learning.log.
    func noteHotwords(rawText: String, hotwords: [String]) {
        guard !rawText.isEmpty, !hotwords.isEmpty else { return }
        let lower = rawText.lowercased()
        let hit = hotwords.filter { !$0.isEmpty && lower.contains($0.lowercased()) }
        guard !hit.isEmpty else { return }
        journal.bumpHotwordHits(hit)
    }

    /// Tally which official spellings `HotwordSnapper` actually restored. Lets the
    /// nightly report tell a snapper that earns its keep from one that never fires.
    func noteSnapperHits(_ spellings: [String]) {
        guard !spellings.isEmpty else { return }
        journal.bumpSnapperHits(spellings)
        journal.log("SNAP    热词吸附命中: \(spellings.joined(separator: " "))")
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
