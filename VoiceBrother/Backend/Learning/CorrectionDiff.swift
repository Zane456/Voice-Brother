import Foundation

/// Pure, dependency-free diff that turns a (transcription, user-correction)
/// pair into a minimal find→replace rule.
///
/// This mirrors the role of 豆包输入法's `ASRContext.ModifyPair`: a correction
/// is reduced to the smallest changed span so it generalises to future
/// transcriptions instead of memorising one whole sentence.
///
/// The function is intentionally a pure value transform — no I/O, no state —
/// so it can never affect the recording path and is trivial to reason about.
enum CorrectionDiff {

    struct Pair: Equatable {
        let from: String
        let to: String
    }

    /// A 1-character `from` would replace that character everywhere it occurs
    /// (dangerous: 他/她/它), so the minimum is 2. A span longer than `maxSpan`
    /// is a sentence rewrite rather than a term correction — not worth learning.
    private static let minFrom = 2
    private static let maxSpan = 24

    /// Reduce a correction to its minimal — then word-aligned — changed span.
    ///
    /// Returns `nil` when the change is not a safe, generalisable replacement:
    /// no change, pure insertion/deletion, a whole-sentence rewrite, or a span
    /// too short to replace safely.
    static func extract(original rawOriginal: String, corrected rawCorrected: String) -> Pair? {
        let original = rawOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = rawCorrected.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !original.isEmpty, !corrected.isEmpty, original != corrected else { return nil }

        let o = Array(original)
        let c = Array(corrected)

        // Longest common prefix.
        var prefix = 0
        while prefix < o.count && prefix < c.count && o[prefix] == c[prefix] {
            prefix += 1
        }

        // Longest common suffix that does not overlap the prefix.
        var suffix = 0
        while suffix < (o.count - prefix)
            && suffix < (c.count - prefix)
            && o[o.count - 1 - suffix] == c[c.count - 1 - suffix] {
            suffix += 1
        }

        // Word alignment: a correction that lands inside an English word (e.g.
        // "s"→"S" within "skill") must learn the WHOLE word, not the 1-char
        // span — a 1-char literal replace would corrupt every other word.
        // The borrowed characters come from the common prefix/suffix, so they
        // are identical on both sides and the from→to mapping stays valid.
        while prefix > 0, isWordChar(o[prefix - 1]) {
            prefix -= 1
        }
        while suffix > 0, isWordChar(o[o.count - suffix]) {
            suffix -= 1
        }

        let from = String(o[prefix ..< (o.count - suffix)])
        let to = String(c[prefix ..< (c.count - suffix)])

        // Pure insertion or deletion — not a reliable replacement rule.
        guard !from.isEmpty, !to.isEmpty else { return nil }
        // Too short to replace safely (e.g. a single CJK homophone), or too
        // long to be a term correction rather than a sentence rewrite.
        guard from.count >= minFrom else { return nil }
        guard from.count <= maxSpan, to.count <= maxSpan else { return nil }
        // No shared context AND a long span ⇒ the user rewrote the whole
        // sentence rather than fixing a term. Don't learn that as a rule.
        guard !(prefix == 0 && suffix == 0 && from.count > 8) else { return nil }
        // A target that still contains the source is the sign of a bad
        // (non-minimal) diff — reject it rather than learn garbage.
        guard !to.contains(from) else { return nil }

        return Pair(from: from, to: to)
    }

    /// ASCII letters and digits — the characters that make up an English word
    /// or number token. CJK characters are deliberately excluded: each is its
    /// own token, so a CJK correction should not pull in its neighbours.
    private static func isWordChar(_ ch: Character) -> Bool {
        ch.isASCII && (ch.isLetter || ch.isNumber)
    }
}
