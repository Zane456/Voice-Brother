import Foundation

/// 字符串规范化 —— `HotwordSnapper` 和 `PhoneticGate` 共用的**唯一**实现。
///
/// 规则：小写 → 中文数字映射成阿拉伯数字 → 只留 `[a-z0-9]`，其余全丢。
///
///     "G L M"     → "glm"
///     "O.K."      → "ok"
///     "simu link" → "simulink"
///     "N八N"      → "n8n"
///     "V一"       → "v1"
///
/// ⚠️ 这个文件必须保持零 app 依赖（只 import Foundation），
/// 才能被 scratchpad 里的 swiftc 断言 harness 单独编译验证。
enum PhoneticNormalize {

    /// 中文数字 → 阿拉伯数字。只收单字数字，不收「十百千万」——
    /// 后者是位值词不是字面数字，`二十` 该由 ITNProcessor 上下文感知地转，
    /// 在这里映射会让 `第十` 之类误规范化。
    private static let cjkDigits: [Character: Character] = [
        "〇": "0", "零": "0",
        "一": "1", "二": "2", "三": "3", "四": "4", "五": "5",
        "六": "6", "七": "7", "八": "8", "九": "9",
    ]

    static func isCJKDigit(_ ch: Character) -> Bool {
        cjkDigits[ch] != nil
    }

    /// 规范化键。丢弃一切非 ASCII 字母数字（含全部汉字），中文数字先折成阿拉伯数字。
    static func key(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if let digit = cjkDigits[ch] {
                out.append(digit)
            } else if ch.isASCII, ch.isLetter || ch.isNumber {
                out.append(contentsOf: ch.lowercased())
            }
        }
        return out
    }

    /// `key()` 会把汉字整个丢掉，所以两个含不同汉字的串可能得到相同的键
    /// （"啊哈GLM" 和 "GLM哦" 都是 "glm"）。凡是要用「键相等」下结论的地方，
    /// 必须先用本函数确认串里没有承载语义的字符——
    /// 只允许 ASCII 字母数字、中文数字、以及标点/空白这些纯分隔符。
    static func isKeySafe(_ s: String) -> Bool {
        for ch in s {
            if cjkDigits[ch] != nil { continue }
            if ch.isASCII, ch.isLetter || ch.isNumber { continue }
            if ch.isWhitespace || ch.isPunctuation || ch.isSymbol { continue }
            return false      // 汉字、假名、emoji 等有实义的字符
        }
        return true
    }
}
