import Foundation

/// Layer 2: Inverse Text Normalization — convert spoken forms to written forms.
///
/// Handles: Chinese numbers → Arabic, dates, percentages, currency, time,
/// phone numbers, and simple math expressions.
enum ITNProcessor {

    // MARK: - Public API

    /// Apply all ITN transformations.
    static func process(_ text: String) -> String {
        var result = text

        // 0. Revert ASR artifacts: "1个" → "一个" (runs first so downstream converters re-convert where needed)
        result = revertASRArtifacts(result)

        // Order matters: specific patterns before generic number conversion
        // 1. Math expressions (before number conversion to preserve operator context)
        result = convertMathExpressions(result)
        // 2. Percentages ("百分之十五" → "15%")
        result = convertPercentages(result)
        // 3. Dates ("三月二十九号" → "3月29日")
        result = convertDates(result)
        // 4. Time ("下午三点半" → "下午3:30")
        result = convertTime(result)
        // 5. Decimals ("三点五" → "3.5")
        result = convertDecimals(result)
        // 6. Currency ("两百块钱" → "200元")
        result = convertCurrency(result)
        // 7. Phone numbers / digit sequences ("零二一" → "021")
        result = convertPhoneNumbers(result)
        // 8. Generic standalone numbers ("一千二百三十四" → "1234")
        result = convertStandaloneNumbers(result)

        return result
    }

    // MARK: - ASR Artifact Revert

    /// Revert ASR-originated "1" back to "一" when followed by a CJK character.
    /// ASR engines often output "1个" instead of "一个" — these are indefinite articles,
    /// not numbers. Runs before other ITN converters so they can re-convert where appropriate
    /// (e.g. "一元" → "1元" by currency converter).
    private static func revertASRArtifacts(_ text: String) -> String {
        var chars = Array(text)
        guard chars.count >= 2 else { return text }
        for i in 0..<(chars.count - 1) {
            guard chars[i] == "1" else { continue }
            // Check next char is CJK (U+4E00–U+9FFF)
            let next = chars[i + 1]
            guard let scalar = next.unicodeScalars.first else { continue }
            let v = scalar.value
            guard (0x4E00...0x9FFF).contains(v) else { continue }
            // Don't revert if preceded by digit or "." (part of a larger number)
            if i > 0 {
                let prev = chars[i - 1]
                if prev.isNumber || prev == "." { continue }
            }
            chars[i] = "一"
        }
        return String(chars)
    }

    // MARK: - Chinese Number Parsing

    /// Map single Chinese digit characters to their numeric values.
    private static let digitMap: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "幺": 1, "二": 2, "两": 2,
        "三": 3, "四": 4, "五": 5, "六": 6, "七": 7,
        "八": 8, "九": 9,
    ]

    /// Characters that form Chinese numbers (digits + units).
    private static let numberChars: Set<Character> = {
        var chars = Set(digitMap.keys)
        chars.formUnion(["十", "百", "千", "万", "亿"])
        return chars
    }()

    /// Parse a Chinese number string to an integer.
    /// Returns nil if the string cannot be parsed.
    ///
    /// Handles patterns like:
    /// - "十五" → 15
    /// - "二十" → 20
    /// - "一百二十三" → 123
    /// - "一千二百三十四" → 1234
    /// - "三百万" → 3_000_000
    /// - "一亿两千万" → 120_000_000
    static func parseChineseNumber(_ text: String) -> Int? {
        guard !text.isEmpty else { return nil }

        let chars = Array(text)

        // Single digit
        if chars.count == 1, let d = digitMap[chars[0]] {
            return d
        }

        // Split by 亿, parse each part
        let yiParts = text.components(separatedBy: "亿")
        if yiParts.count == 2 {
            let high = parseBelowYi(yiParts[0])
            let low = yiParts[1].isEmpty ? 0 : parseBelowYi(yiParts[1])
            guard let h = high, let l = low else { return nil }
            return h * 100_000_000 + l
        }

        return parseBelowYi(text)
    }

    /// Parse number below 亿 (handles 万 as the highest unit).
    private static func parseBelowYi(_ text: String) -> Int? {
        guard !text.isEmpty else { return nil }

        let wanParts = text.components(separatedBy: "万")
        if wanParts.count == 2 {
            let high = parseBelowWan(wanParts[0])
            let low = wanParts[1].isEmpty ? 0 : parseBelowWan(wanParts[1])
            guard let h = high, let l = low else { return nil }
            return h * 10_000 + l
        }

        return parseBelowWan(text)
    }

    /// Parse number below 万 (千/百/十/个).
    private static func parseBelowWan(_ text: String) -> Int? {
        guard !text.isEmpty else { return nil }

        var total = 0
        var current = 0
        var hasUnit = false
        let chars = Array(text)

        for (i, ch) in chars.enumerated() {
            if let d = digitMap[ch] {
                current = d
            } else {
                switch ch {
                case "十":
                    // Handle implicit "一十" → "十五" means 15
                    total += (current == 0 && i == 0 ? 1 : current) * 10
                    current = 0
                    hasUnit = true
                case "百":
                    total += current * 100
                    current = 0
                    hasUnit = true
                case "千":
                    total += current * 1000
                    current = 0
                    hasUnit = true
                default:
                    return nil // unexpected character
                }
            }
        }

        total += current

        // Must have at least one unit for multi-char strings, or be a single digit
        if chars.count > 1 && !hasUnit && current == total {
            // This is just consecutive digits with no units — not a standard Chinese number
            return nil
        }

        return total
    }

    /// Format a parsed number as a string.
    private static func formatNumber(_ n: Int) -> String {
        String(n)
    }

    // MARK: - Percentages

    /// "百分之十五" → "15%", "百分之三十点五" → "30.5%"
    private static func convertPercentages(_ text: String) -> String {
        // Match 百分之 followed by Chinese number (with optional decimal)
        let pattern = "百分之([零一二两三四五六七八九十百千]+)(?:点([零一二两三四五六七八九]+))?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString

        var result = text
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        // Process in reverse to preserve indices
        for match in matches.reversed() {
            let intPart = nsText.substring(with: match.range(at: 1))
            guard let intValue = parseChineseNumber(intPart) else { continue }

            var replacement = "\(intValue)"

            if match.range(at: 2).location != NSNotFound {
                let decPart = nsText.substring(with: match.range(at: 2))
                let decimals = decPart.compactMap { digitMap[$0] }.map(String.init).joined()
                replacement += ".\(decimals)"
            }

            replacement += "%"
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }

        return result
    }

    // MARK: - Dates

    /// "三月二十九号" → "3月29日", "二零二六年" → "2026年"
    private static func convertDates(_ text: String) -> String {
        var result = text

        // Year: "二零二六年" → "2026年" (digit-by-digit)
        let yearPattern = "([零〇一二三四五六七八九]{4})年"
        if let regex = try? NSRegularExpression(pattern: yearPattern) {
            let nsText = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsText.length))
            for match in matches.reversed() {
                let yearStr = nsText.substring(with: match.range(at: 1))
                let digits = yearStr.compactMap { digitMap[$0] }
                if digits.count == 4 {
                    let year = digits.map(String.init).joined()
                    result = (result as NSString).replacingCharacters(
                        in: match.range,
                        with: "\(year)年"
                    )
                }
            }
        }

        // Month + Day: "三月二十九号/日" → "3月29日"
        let mdPattern = "([一二三四五六七八九十]+)月([一二三四五六七八九十]+)[号日]"
        if let regex = try? NSRegularExpression(pattern: mdPattern) {
            let nsText = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsText.length))
            for match in matches.reversed() {
                let monthStr = nsText.substring(with: match.range(at: 1))
                let dayStr = nsText.substring(with: match.range(at: 2))
                guard let month = parseChineseNumber(monthStr),
                      let day = parseChineseNumber(dayStr),
                      (1...12).contains(month), (1...31).contains(day) else { continue }
                result = (result as NSString).replacingCharacters(
                    in: match.range,
                    with: "\(month)月\(day)日"
                )
            }
        }

        // Standalone month: "三月" → "3月" (only if not already converted)
        let monthOnlyPattern = "(?<![0-9])([一二三四五六七八九十]+)月(?![0-9])"
        if let regex = try? NSRegularExpression(pattern: monthOnlyPattern) {
            let nsText = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsText.length))
            for match in matches.reversed() {
                let monthStr = nsText.substring(with: match.range(at: 1))
                guard let month = parseChineseNumber(monthStr), (1...12).contains(month) else { continue }
                result = (result as NSString).replacingCharacters(
                    in: match.range,
                    with: "\(month)月"
                )
            }
        }

        return result
    }

    // MARK: - Time

    /// "下午三点半" → "下午3:30", "十一点四十五分" → "11:45"
    /// "三点五" → skipped (decimal, handled by convertDecimals)
    /// "三点过五分" → "3:05"
    private static func convertTime(_ text: String) -> String {
        // Group 1: time prefix (上午/下午 etc., may be empty)
        // Group 2: hour digits
        // Group 3: 过 (optional, marks clear time intent)
        // Group 4: minute digits (optional)
        // Group 5: 分 (optional)
        // Group 6: 半
        // Group 7: 整
        let timePattern = "((?:上午|下午|早上|晚上|中午|凌晨)?)([一二三四五六七八九十两]+)点" +
                          "(?:(过)?([零一二三四五六七八九十两]+)(分)?|(半)|(整))?"
        guard let regex = try? NSRegularExpression(pattern: timePattern) else { return text }
        let nsText = text as NSString
        var result = text

        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches.reversed() {
            let hourStr = nsText.substring(with: match.range(at: 2))
            guard let hour = parseChineseNumber(hourStr), (1...24).contains(hour) else { continue }

            let hasPrefix = match.range(at: 1).length > 0
            let prefix = hasPrefix ? nsText.substring(with: match.range(at: 1)) : ""

            // Skip bare "X点" without time context — "一点" likely means "a little", not "1 o'clock"
            let hasMinuteInfo = match.range(at: 6).location != NSNotFound ||
                                match.range(at: 7).location != NSNotFound ||
                                match.range(at: 4).location != NSNotFound
            if !hasMinuteInfo && !hasPrefix {
                continue
            }

            var minute = 0

            if match.range(at: 6).location != NSNotFound {
                // "半"
                minute = 30
            } else if match.range(at: 7).location != NSNotFound {
                // "整"
                minute = 0
            } else if match.range(at: 4).location != NSNotFound {
                let minStr = nsText.substring(with: match.range(at: 4))
                guard let m = parseChineseNumber(minStr), (0...59).contains(m) else { continue }
                minute = m

                let hasFen = match.range(at: 5).location != NSNotFound
                let hasGuo = match.range(at: 3).location != NSNotFound
                let startsWithZero = minStr.hasPrefix("零") || minStr.hasPrefix("〇")

                // "三点五" (single-digit minute, no 分, no 过, no leading 零, no time prefix)
                // → ambiguous, skip and let decimal converter handle it as 3.5
                if m >= 1 && m <= 9 && !hasFen && !hasGuo && !startsWithZero && !hasPrefix {
                    continue
                }
            }

            let timeStr = minute == 0
                ? "\(prefix)\(hour)点"
                : "\(prefix)\(hour):\(String(format: "%02d", minute))"

            result = (result as NSString).replacingCharacters(in: match.range, with: timeStr)
        }

        return result
    }

    // MARK: - Decimals

    /// "三点五" → "3.5", "一百二十三点四五" → "123.45"
    private static func convertDecimals(_ text: String) -> String {
        let pattern = "([零一二两三四五六七八九十百千万亿]+)点([零一二三四五六七八九]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        var result = text

        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches.reversed() {
            let intPart = nsText.substring(with: match.range(at: 1))
            let decPart = nsText.substring(with: match.range(at: 2))

            guard let intValue = parseChineseNumber(intPart) else { continue }
            let decimals = decPart.compactMap { digitMap[$0] }.map(String.init).joined()
            guard !decimals.isEmpty else { continue }

            result = (result as NSString).replacingCharacters(
                in: match.range, with: "\(intValue).\(decimals)"
            )
        }

        return result
    }

    // MARK: - Currency

    /// "两百块钱" → "200元", "一千五百万元" → "1500万元", "三块五" → "3.5元"
    private static func convertCurrency(_ text: String) -> String {
        var result = text

        // Pattern: Chinese number + 块钱/块/元
        // 裸"元"加负向前瞻：后面跟数字 / 组运表方函 / 件素 时不当货币——
        // 这些是数学 / 编程 / 固定词，不是钱。挡住：
        //   一元二次方程 二元一次方程（元+数字）、三元组 三元运算符 三元表达式
        //   一元方程 一元函数、元件 元素。真货币的"元"后面只跟标点/的/了/整/结尾，
        //   绝不跟这些字，所以排除它们对货币转换零损失。
        let currencyPattern = "([零一二两三四五六七八九十百千万亿]+)(?:块钱|块([一二三四五六七八九])[毛角]?|元(?![零一二两三四五六七八九十组运表件素方函]))"
        if let regex = try? NSRegularExpression(pattern: currencyPattern) {
            let nsText = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsText.length))
            for match in matches.reversed() {
                let numStr = nsText.substring(with: match.range(at: 1))
                guard let value = parseChineseNumber(numStr) else { continue }

                var replacement = "\(value)"
                // Handle "三块五" → "3.5元"
                if match.range(at: 2).location != NSNotFound {
                    let decimal = nsText.substring(with: match.range(at: 2))
                    if let d = digitMap[Character(decimal)] {
                        replacement += ".\(d)"
                    }
                }
                replacement += "元"
                result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
            }
        }

        return result
    }

    // MARK: - Phone Numbers / Digit Sequences

    /// "零二一" → "021", "一三八零零零零五六七八" → "13800005678"
    /// Also handles mixed sequences: "070幺54325幺七" → "07015432517"
    private static func convertPhoneNumbers(_ text: String) -> String {
        // Step 1: Pure Chinese digit sequences (3+ chars)
        let digitChars = "零〇一幺二三四五六七八九"
        let purePattern = "([\(digitChars)]{3,})"
        if let regex = try? NSRegularExpression(pattern: purePattern) {
            var nsText = text as NSString
            var result = text
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches.reversed() {
                let seq = nsText.substring(with: match.range)
                let digits = seq.compactMap { digitMap[$0] }.map(String.init).joined()
                if !digits.isEmpty {
                    result = (result as NSString).replacingCharacters(in: match.range, with: digits)
                }
            }
            // Step 2: Mixed sequences — Arabic digits interleaved with Chinese digits
            // Pattern: a sequence that contains both [0-9] and Chinese digit chars, total 3+ chars
            // e.g. "070幺54325幺七"
            let mixedPattern = "([0-9零〇一幺二三四五六七八九]{3,})"
            nsText = result as NSString
            if let mixedRegex = try? NSRegularExpression(pattern: mixedPattern) {
                let mixedMatches = mixedRegex.matches(in: result, range: NSRange(location: 0, length: nsText.length))
                for match in mixedMatches.reversed() {
                    let seq = nsText.substring(with: match.range)
                    // Only process if it contains at least one Chinese digit
                    let hasChinese = seq.contains(where: { digitMap[$0] != nil })
                    guard hasChinese else { continue }
                    // Convert each char: Arabic stays, Chinese → Arabic
                    let converted = seq.map { ch -> String in
                        if let d = digitMap[ch] { return "\(d)" }
                        return String(ch) // already Arabic digit
                    }.joined()
                    result = (result as NSString).replacingCharacters(in: match.range, with: converted)
                }
            }
            return result
        }

        return text
    }

    // MARK: - Standalone Numbers

    /// Convert remaining Chinese number expressions (3+ chars with units) to Arabic.
    /// Avoids converting single digits or short patterns that might be idiomatic.
    /// Skips ordinals: "第十一" stays as-is (preceded by 第).
    private static func convertStandaloneNumbers(_ text: String) -> String {
        // Match Chinese number sequences that contain at least one unit (十百千万亿)
        let pattern = "([零一二两三四五六七八九十百千万亿]{2,})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString

        var result = text
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches.reversed() {
            let numStr = nsText.substring(with: match.range)
            // Only convert if it contains a unit character (十百千万亿) — avoids converting
            // bare digit sequences that should have been handled by phone number pattern
            let hasUnit = numStr.contains(where: { "十百千万亿".contains($0) })
            guard hasUnit, let value = parseChineseNumber(numStr) else { continue }

            // Skip ordinals: don't convert numbers preceded by "第"
            let beforeIdx = match.range.location - 1
            if beforeIdx >= 0 {
                let charBefore = nsText.substring(with: NSRange(location: beforeIdx, length: 1))
                if charBefore == "第" { continue }
            }

            result = (result as NSString).replacingCharacters(in: match.range, with: "\(value)")
        }

        return result
    }

    // MARK: - Math Expressions

    /// Convert spoken math to symbols.
    private static func convertMathExpressions(_ text: String) -> String {
        var result = text

        // Only enter math mode if text contains math trigger words
        let mathTriggers = ["加", "减", "乘", "除", "等于", "大于", "小于", "不等于",
                            "平方", "立方", "次方", "分之", "根号"]
        let hasMath = mathTriggers.contains(where: { result.contains($0) })
        guard hasMath else { return result }

        // Comparison operators (longer patterns first)
        result = result.replacingOccurrences(of: "大于等于", with: "≥")
        result = result.replacingOccurrences(of: "小于等于", with: "≤")
        result = result.replacingOccurrences(of: "不等于", with: "≠")
        // "不大于"=≤、"不小于"=≥ — 必须在裸"大于"/"小于"之前，否则
        // "电压不大于600V"会被切成"电压不>600V"这种垃圾。
        result = result.replacingOccurrences(of: "不大于", with: "≤")
        result = result.replacingOccurrences(of: "不小于", with: "≥")
        result = result.replacingOccurrences(of: "大于", with: ">")
        result = result.replacingOccurrences(of: "小于", with: "<")

        // "等于" — only convert when NOT followed by question words (多少/什么/几/哪/谁/怎)
        result = replacePattern(result, pattern: "等于(?![多少什么几哪谁怎])", with: "=")

        // Arithmetic operators
        result = result.replacingOccurrences(of: "乘以", with: "×")
        result = result.replacingOccurrences(of: "除以", with: "÷")
        // "加"/"减" only between numbers — avoid corrupting words like "添加"/"减少"/"加一个"
        result = replacePattern(result, pattern: "(?<=[0-9零一二两三四五六七八九十百千万亿])\\s*加\\s*(?=[0-9零一二两三四五六七八九十百千万亿])", with: "+")
        result = replacePattern(result, pattern: "(?<=[0-9零一二两三四五六七八九十百千万亿])\\s*减\\s*(?=[0-9零一二两三四五六七八九十百千万亿])", with: "-")

        // Powers: "X的平方" → "X²", "X的立方" → "X³", "X的N次方" → "Xⁿ"
        result = convertPowers(result)

        // Fractions: "N分之M" → "M/N" (note the reversal)
        result = convertFractions(result)

        // Square root: "根号X" → "√X"
        result = result.replacingOccurrences(of: "根号", with: "√")

        // Convert Chinese digits adjacent to math symbols to Arabic
        result = convertMathAdjacentDigits(result)

        return result
    }

    /// Convert power expressions.
    private static func convertPowers(_ text: String) -> String {
        var result = text

        // "平方" → "²" — "的" is optional (ASR often omits it)
        // Negative lookahead: don't convert "平方米/千米/公里" (area units)
        result = replacePattern(result, pattern: "(?:的)?平方(?!米|千米|公里|厘米|分米|毫米)", with: "²")
        // "立方" → "³" — same optional "的"
        result = replacePattern(result, pattern: "(?:的)?立方(?!米|千米|公里|厘米|分米|毫米)", with: "³")

        // "N次方" — "的" is optional; convert known small exponents to superscript
        let superscripts: [String: String] = [
            "零": "⁰", "一": "¹", "二": "²", "三": "³", "四": "⁴",
            "五": "⁵", "六": "⁶", "七": "⁷", "八": "⁸", "九": "⁹",
        ]

        let powerPattern = "(?:的)?([零一二三四五六七八九十百千]+)次方"
        if let regex = try? NSRegularExpression(pattern: powerPattern) {
            let nsText = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsText.length))
            for match in matches.reversed() {
                let numStr = nsText.substring(with: match.range(at: 1))
                if numStr.count == 1, let sup = superscripts[numStr] {
                    result = (result as NSString).replacingCharacters(in: match.range, with: sup)
                } else if let n = parseChineseNumber(numStr) {
                    // Multi-digit exponent: use ^n notation
                    result = (result as NSString).replacingCharacters(in: match.range, with: "^\(n)")
                }
            }
        }

        return result
    }

    /// Convert Chinese digits that are adjacent to math symbols (operators, superscripts, etc.)
    /// "三+三" → "3+3", "十²" → "10²", "九" after "=" → "9"
    private static func convertMathAdjacentDigits(_ text: String) -> String {
        let mathSymbols: Set<Character> = ["+", "-", "×", "÷", "=", ">", "<", "≥", "≤", "≠",
                                           "²", "³", "⁰", "¹", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹",
                                           "√", "/", "^", "(", ")"]

        var result = Array(text)
        var changed = true

        // Iterate until no more changes (cascading conversions)
        while changed {
            changed = false
            let str = String(result)

            // Find Chinese number segments adjacent to math symbols
            let pattern = "([零一二两三四五六七八九十百千万亿]+)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { break }
            let nsStr = str as NSString
            let matches = regex.matches(in: str, range: NSRange(location: 0, length: nsStr.length))

            for match in matches.reversed() {
                let range = match.range
                let numStr = nsStr.substring(with: range)

                // Check if adjacent to a math symbol (before or after)
                let beforeIdx = range.location - 1
                let afterIdx = range.location + range.length

                let adjacentBefore = beforeIdx >= 0 && mathSymbols.contains(Character(nsStr.substring(with: NSRange(location: beforeIdx, length: 1))))
                let adjacentAfter = afterIdx < nsStr.length && mathSymbols.contains(Character(nsStr.substring(with: NSRange(location: afterIdx, length: 1))))

                guard adjacentBefore || adjacentAfter else { continue }

                // Try to parse and convert
                if let value = parseChineseNumber(numStr) {
                    let replacement = "\(value)"
                    if replacement != numStr {
                        result = Array((String(result) as NSString).replacingCharacters(in: range, with: replacement))
                        changed = true
                        break // restart since indices shifted
                    }
                }
            }
        }

        return String(result)
    }

    /// Regex helper for math expressions.
    private static func replacePattern(_ text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    /// Convert fraction expressions: "N分之M" → "M/N".
    private static func convertFractions(_ text: String) -> String {
        let fractionPattern = "([零一二两三四五六七八九十百千万]+)分之([零一二两三四五六七八九十百千万]+)"
        guard let regex = try? NSRegularExpression(pattern: fractionPattern) else { return text }
        let nsText = text as NSString
        var result = text

        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches.reversed() {
            let denomStr = nsText.substring(with: match.range(at: 1))
            let numerStr = nsText.substring(with: match.range(at: 2))
            guard let denom = parseChineseNumber(denomStr),
                  let numer = parseChineseNumber(numerStr),
                  denom != 0 else { continue }
            result = (result as NSString).replacingCharacters(in: match.range, with: "\(numer)/\(denom)")
        }

        return result
    }
}
