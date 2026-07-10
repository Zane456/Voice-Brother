import Foundation

/// 把 ASR 输出里「形近热词」的片段吸附回热词的官方拼写。
///
///     "你说我G L M没钱了"        → "你说我GLM没钱了"
///     "跑一下simu link"          → "跑一下simulink"
///     "为什么要研究D A B？"      → "为什么要研究DAB？"
///
/// **零误伤是硬要求**，靠三条约束保证：
///
/// 1. **规范化后必须精确相等**。`cloud` 规范化是 `cloud`，`Claude` 是 `claude`，不相等
///    → `cloud storage` 永远不会被改成 `Claude storage`。发音近似匹配（Metaphone 之类）
///    会撞上常用英文词，一律不做。
/// 2. **只在整 token 窗口上匹配**。`MOSFET` 是一个 token，子串 `OS` 不可能被选中，
///    所以不需要词边界正则。
/// 3. **只差大小写不吸附**。热词表里混着 `Wait`/`Actually`/`Draft`/`skill`/`token`
///    这些普通英文词（夜间脚本从 Claude 回复里挖的）。若允许纯大小写吸附，
///    `please wait` 会变成 `please Wait`，用户打的 `Skill` 会被降成 `skill`。
///    大小写规范交给 LLM polish / 手动规则，这里不碰。
///
/// 另有三道防护：
/// - **歧义键丢弃**：热词表同时有 `Codex` 和 `codex`，规范化后同为 `codex`，无从择优 → 整个键不参与吸附
/// - **skip-set**：片段若已经等于词表里*任何一个*官方拼写，就不动它（防 `CodeX` 被改写成热词 `Codex`）
/// - **单字符 token 连续段是原子的**：不许从中间切断。ASR 把缩写读成一串单字母
///   （`A P I`、`K I C A D`、`L V D C`），若允许滑窗退化去吃其中一截，短热词
///   `PI` / `IC` / `DC` 就会命中，把 `A P I key` 毁成 `A PI key`。整段查不到就整段不动。
///
/// ⚠️ 必须跑在 `applyReplacements` **之后**。若跑在之前，`code x` 会先被吸附成
/// 热词 `Codex`，用户显式配置的手动规则 `code x → CodeX` 就再也匹配不到——
/// 吸附器悄悄推翻了用户的规则。
///
/// ⚠️ 零 app 依赖（只 import Foundation），供 swiftc 断言 harness 单独编译。
struct HotwordSnapper {

    struct Result {
        let text: String
        /// 本次实际吸附命中的官方拼写，喂给 LearningJournal 记账。
        let hits: [String]
    }

    /// 规范化键 → 官方拼写。歧义键（一键多拼写）已剔除。
    private let dict: [String: String]
    /// 全部官方拼写的精确集合。片段命中它就原样保留。
    private let skip: Set<String>
    /// 单个窗口最多吃几个 token。每个 token 至少贡献 1 个规范化字符，
    /// 所以最长键的长度就是安全上界。
    private let maxTokensPerWindow: Int

    init(targets: [String]) {
        var buckets: [String: Set<String>] = [:]
        var spellings = Set<String>()
        for raw in targets {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let k = PhoneticNormalize.key(t)
            guard !k.isEmpty else { continue }
            buckets[k, default: []].insert(t)
            spellings.insert(t)
        }
        var resolved: [String: String] = [:]
        for (k, set) in buckets where set.count == 1 {
            resolved[k] = set.first!
        }
        self.dict = resolved
        self.skip = spellings
        self.maxTokensPerWindow = max(1, resolved.keys.map(\.count).max() ?? 1)
    }

    // MARK: - 主流程

    func snap(_ text: String) -> Result {
        guard !dict.isEmpty, !text.isEmpty else { return Result(text: text, hits: []) }

        let chars = Array(text)
        var out = ""
        out.reserveCapacity(chars.count)
        var hits: [String] = []

        var i = 0
        while i < chars.count {
            guard Self.isRunCore(chars[i]) else {
                out.append(chars[i])
                i += 1
                continue
            }
            let runEnd = Self.runEnd(chars, from: i)          // [i, runEnd)
            let (snapped, runHits) = snapRun(chars, i, runEnd)
            out += snapped
            hits += runHits
            i = runEnd
        }
        return Result(text: out, hits: hits)
    }

    /// 在一个 run 内部按 token 滑窗，长者优先。
    private func snapRun(_ chars: [Character], _ lo: Int, _ hi: Int) -> (String, [String]) {
        let tokens = Self.tokenRanges(chars, lo, hi)
        guard !tokens.isEmpty else { return (String(chars[lo..<hi]), []) }

        // 单字符 token（ASR 把缩写读成一串单字母时产生），用于原子段判定。
        let isSingle = tokens.map { $0.count == 1 }

        var out = ""
        var hits: [String] = []
        var cursor = lo                     // 已输出到的字符位置
        var t = 0

        while t < tokens.count {
            var matched = false
            let maxSpan = min(t + maxTokensPerWindow, tokens.count)
            // 长者优先：先试最长的 token 窗口
            var end = maxSpan
            while end > t {
                guard Self.windowRespectsAtomicRuns(isSingle, t, end) else { end -= 1; continue }
                let spanLo = tokens[t].lowerBound
                let spanHi = tokens[end - 1].upperBound
                let span = String(chars[spanLo..<spanHi])
                if let official = candidate(for: span) {
                    out += String(chars[cursor..<spanLo])     // 窗口前的分隔符原样输出
                    out += official
                    hits.append(official)
                    cursor = spanHi
                    t = end
                    matched = true
                    break
                }
                end -= 1
            }
            if !matched { t += 1 }
        }
        out += String(chars[cursor..<hi])
        return (out, hits)
    }

    /// 窗口 `[t, end)` 是否没有把「单字符 token 连续段」拦腰截断。
    ///
    /// 首 token 若是单字符，它必须是所在连续段的**起点**；
    /// 末 token 若是单字符，它必须是所在连续段的**终点**。
    ///
    /// `A P I key` → 段是 `[A P I]`。窗口 `[P I]` 从段中间起步 → 拒绝，
    /// 于是 `PI` 这个短热词命中不了，`A P I` 整体查不到就原样保留。
    /// `C H三` → `H三` 不是单字符，窗口 `[C, H三]` 合法，`Ch3` 照常吸附。
    private static func windowRespectsAtomicRuns(_ isSingle: [Bool], _ t: Int, _ end: Int) -> Bool {
        if isSingle[t], t > 0, isSingle[t - 1] { return false }
        if isSingle[end - 1], end < isSingle.count, isSingle[end] { return false }
        return true
    }

    /// 该片段该被吸附成哪个官方拼写？不该动就返回 nil。
    private func candidate(for span: String) -> String? {
        let k = PhoneticNormalize.key(span)
        guard !k.isEmpty, let official = dict[k] else { return nil }
        guard span != official else { return nil }              // 已经是官方拼写
        guard !skip.contains(span) else { return nil }          // 是别的官方拼写，别动
        guard span.lowercased() != official.lowercased() else { return nil }  // 只差大小写，不碰
        return official
    }

    // MARK: - run / token 切分

    /// run 的骨架字符：ASCII 字母数字，或中文数字（为了吃下 `N八N`）。
    private static func isRunCore(_ ch: Character) -> Bool {
        (ch.isASCII && (ch.isLetter || ch.isNumber)) || PhoneticNormalize.isCJKDigit(ch)
    }

    /// run 的粘合字符：空白，或 ASCII 标点。
    /// 全角标点（`？`、`。`）不算——它们是 run 的边界。
    private static func isRunGlue(_ ch: Character) -> Bool {
        ch.isWhitespace || (ch.isASCII && (ch.isPunctuation || ch.isSymbol))
    }

    /// 从 `lo`（必为 core）出发，返回 run 的开区间右端。run 以 core 字符结尾，
    /// 尾部的粘合字符被排除在外（`O.K.` 的 run 是 `O.K`，末尾的 `.` 留给正文）。
    private static func runEnd(_ chars: [Character], from lo: Int) -> Int {
        var j = lo
        var lastCore = lo
        while j < chars.count, isRunCore(chars[j]) || isRunGlue(chars[j]) {
            if isRunCore(chars[j]) { lastCore = j }
            j += 1
        }
        return lastCore + 1
    }

    /// run 内按空白切 token，返回每个 token 的字符区间。
    private static func tokenRanges(_ chars: [Character], _ lo: Int, _ hi: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start: Int? = nil
        for i in lo..<hi {
            if chars[i].isWhitespace {
                if let s = start { ranges.append(s..<i); start = nil }
            } else if start == nil {
                start = i
            }
        }
        if let s = start { ranges.append(s..<hi) }
        return ranges
    }
}
