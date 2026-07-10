import Foundation

/// 自动学习的**发音准入闸**。豆包输入法的对应物是 `AsrUserCorrectDict::Add` 里的
/// `length not equal → 拒` + `zhuyin failed → 拒`：它只学「同音同长」的纠错对。
///
/// 为什么需要它：`learn()` 把一次编辑提升成**全局替换规则**，以后每句都跑。
/// 用户改一句话的内容（「内容」→「论文」）和纠一个听错的字（「质朴」→「智谱」）
/// 在字符层面长得一样，只有发音能区分。没有这道闸，前者会被学成规则，
/// 每次说到「内容」都被改写——这正是 2026-06-08「好了 → 我的ext」事故。
///
/// 三条通道，顺序裁决：
///
/// | 通道 | 条件 | 例 |
/// |---|---|---|
/// | ch1 | 规范化后相等（且两侧都不含实义汉字） | `G L M→GLM`、`N八N→n8n`、`code x→CodeX` |
/// | ch2 | 两侧都是纯汉字 → **就地裁决**：字数相同 且 拼音相同 | 放行 `质朴→智谱`；拒 `内容→论文` |
/// | ch3 | `right` 在已知目标词表里，且主体是 ASCII 字母数字 | `cloud→Claude`、`克劳德→Claude` |
/// | else | 一律拒 | `好了→我的ext`（`我的ext` 不在词表里） |
///
/// **不做英文辅音骨架通道**：`bit`/`bat`/`boot` 骨架同为 `bt`，会学出 `bit→bat` 这类
/// 毒规则；而 ch3 已覆盖全部英文用例（英文正词必然在热词表/规则表里）。
///
/// ⚠️ 零 app 依赖（只 import Foundation），供 swiftc 断言 harness 单独编译。
/// ⚠️ 本文件是双端权威。`extensions/dynamic-hotwords/update_hotwords.py` 的
///    `phonetic_gate()` 是它的宽松镜像（pypinyin 取多音字读音交集，多捞），
///    Swift 侧单读音做终审，`evictNonLearnableRules()` 每次启动兜底清扫。
enum PhoneticGate {

    static func allows(_ wrong: String, _ right: String, knownTargets: Set<String>) -> Bool {
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !r.isEmpty, w != r else { return false }

        // ch1 —— 只是空格/标点/大小写/中文数字写法不同，本质是同一串字符。
        if PhoneticNormalize.isKeySafe(w), PhoneticNormalize.isKeySafe(r) {
            let kw = PhoneticNormalize.key(w)
            let kr = PhoneticNormalize.key(r)
            if !kw.isEmpty, kw == kr { return true }
        }

        // ch2 —— 两侧都是纯汉字：同音同长才是听错字，否则是改写内容。
        // 必须就地 return，不能下落到 ch3，否则非同音的汉字对会漏出去。
        if isPureCJK(w), isPureCJK(r) {
            return w.count == r.count && syllables(of: w) == syllables(of: r)
        }

        // ch3 —— 正词是我们已知的英文/数字专名（热词、手动规则的目标词、已学规则的目标词）。
        // 这是中→英音译（克劳德→Claude）和英文近音（cloud→Claude）的准入路径。
        // 白名单约束是安全性的来源：`我的ext` 不在词表里，学不进来。
        if knownTargets.contains(r), isMostlyASCIIAlnum(r) { return true }

        return false
    }

    // MARK: - 判定辅助

    /// 全部字符都是 CJK 统一表意文字（含扩展 A 区）。中文数字也算汉字，
    /// 所以 `一二` 走 ch2 而不是 ch1——但 ch1 在前，纯数字对早就被 ITN 闸拦掉了。
    static func isPureCJK(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        for ch in s {
            guard let v = ch.unicodeScalars.first?.value,
                  ch.unicodeScalars.count == 1,
                  (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
            else { return false }
        }
        return true
    }

    /// ASCII 字母数字占比 ≥ 50%。挡住 `right` 是纯中文或纯标点的情况。
    static func isMostlyASCIIAlnum(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let alnum = s.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.count
        return Double(alnum) / Double(s.count) >= 0.5
    }

    // MARK: - 拼音

    private static let pinyinCache = NSCache<NSString, NSArray>()

    /// 无调拼音音节数组。整串做 MandarinLatin 转换（CFStringTransform 会按空格分音节），
    /// 再去声调符号，最后按空格切。整串转换比逐字转换好——多音字能拿到上下文。
    static func syllables(of s: String) -> [String] {
        if let cached = pinyinCache.object(forKey: s as NSString) as? [String] {
            return cached
        }
        let mutable = NSMutableString(string: s) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        let result = (mutable as String)
            .lowercased()
            .split(separator: " ")
            .map(String.init)
        pinyinCache.setObject(result as NSArray, forKey: s as NSString)
        return result
    }
}
