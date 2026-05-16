import SwiftUI

/// Scattered "word cloud" of the user's most frequently used keywords.
/// Word size and color depth both scale with usage frequency — the more a
/// word is used, the larger and darker it appears. Words sit horizontally and
/// bob gently and continuously for a soft, living feel.
struct WordCloudView: View {
    let keywords: [KeywordAnalyzer.Keyword]

    @EnvironmentObject private var theme: ThemeManager
    @State private var appeared = false
    @State private var floating = false

    /// Fixed card height. The box stays put across keyword refreshes so it
    /// never reflows the history list below it — words just animate in
    /// within this constant frame.
    private let cloudHeight: CGFloat = 198

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 10))
                Text("常用词").font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(theme.textTertiary)

            WordCloudLayout {
                ForEach(Array(keywords.enumerated()), id: \.element.id) { index, keyword in
                    chip(keyword, index: index)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: cloudHeight)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .glassCard()
        .onAppear {
            // View (re)created with keywords already loaded — play entrance.
            if !keywords.isEmpty { restartEntrance() }
        }
        .onChange(of: keywords) { _, newValue in
            // Keyword set refreshed (e.g. re-entering the 历史 tab). Replay the
            // staggered entrance so the cloud fades in gently instead of
            // popping. The card height is fixed, so nothing below reflows.
            if !newValue.isEmpty { restartEntrance() }
        }
    }

    /// Snaps every chip back to its hidden state (no animation), then triggers
    /// the staggered scale/fade entrance followed by the perpetual drift.
    private func restartEntrance() {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            appeared = false
            floating = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { appeared = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { floating = true }
    }

    private func chip(_ keyword: KeywordAnalyzer.Keyword, index: Int) -> some View {
        let fontSize = 12.0 + keyword.weight * 18.0          // 12...30 pt
        let opacity = 0.4 + keyword.weight * 0.6             // 0.4...1.0
        let hash = Self.stableHash(keyword.word)
        let driftDuration = 1.9 + Double(hash % 12) / 10.0   // 1.9...3.0 s
        let driftDelay = Double(hash % 19) / 10.0            // 0...1.8 s phase offset
        let amplitude = 3.5

        return Text(keyword.word)
            .font(.system(size: fontSize, weight: keyword.weight > 0.6 ? .semibold : .regular))
            .foregroundColor(theme.textPrimary.opacity(opacity))
            .scaleEffect(appeared ? 1 : 0.55)
            .opacity(appeared ? 1 : 0)
            .animation(.easeOut(duration: 0.42).delay(Double(index) * 0.028), value: appeared)
            .offset(y: floating ? amplitude : -amplitude)
            .animation(
                .easeInOut(duration: driftDuration)
                    .delay(driftDelay)
                    .repeatForever(autoreverses: true),
                value: floating
            )
    }

    /// Deterministic hash so a word's drift timing stays stable across recomputes.
    private static func stableHash(_ string: String) -> Int {
        var hash = 5381
        for scalar in string.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        return abs(hash)
    }
}

/// Packs subviews into a scattered cloud: the first (largest) subview sits at
/// the center, each subsequent one spirals outward to the first
/// non-overlapping slot. The spiral is biased horizontal to suit a wide,
/// short container and to keep the box visually filled.
struct WordCloudLayout: Layout {

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        CGSize(width: proposal.width ?? 320, height: proposal.height ?? 120)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        var placed: [CGRect] = []

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            // Snug footprint — just enough breathing room between words.
            // Kept tight so a large keyword set packs densely and fills the box.
            let footprint = CGSize(width: size.width + 10, height: size.height + 6)
            let position = slot(for: footprint, index: index,
                                center: center, bounds: bounds, placed: placed)
            placed.append(CGRect(x: position.x - footprint.width / 2,
                                 y: position.y - footprint.height / 2,
                                 width: footprint.width, height: footprint.height))
            subview.place(at: position, anchor: .center, proposal: ProposedViewSize(size))
        }
    }

    /// Finds a non-overlapping center point for `size` by walking an
    /// Archimedean spiral outward from the container center.
    private func slot(for size: CGSize, index: Int, center: CGPoint,
                      bounds: CGRect, placed: [CGRect]) -> CGPoint {
        guard index > 0 else { return clamp(center, size: size, in: bounds) }

        let startAngle = Double(index) * 2.39996  // golden angle spreads directions
        var candidate = center
        var step = 0.0
        let maxSteps = 1600.0

        while step < maxSteps {
            let angle = startAngle + step * 0.5
            let radius = step * 1.4
            let point = CGPoint(x: center.x + cos(angle) * radius,
                                y: center.y + sin(angle) * radius * 0.45)  // horizontal bias
            candidate = clamp(point, size: size, in: bounds)
            let rect = CGRect(x: candidate.x - size.width / 2,
                              y: candidate.y - size.height / 2,
                              width: size.width, height: size.height)
            if !placed.contains(where: { $0.intersects(rect) }) {
                return candidate
            }
            step += 1
        }
        return candidate
    }

    /// Keeps a point's footprint fully inside `bounds`.
    private func clamp(_ point: CGPoint, size: CGSize, in bounds: CGRect) -> CGPoint {
        let halfW = size.width / 2
        let halfH = size.height / 2
        guard bounds.width > size.width, bounds.height > size.height else {
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }
        let x = min(max(point.x, bounds.minX + halfW), bounds.maxX - halfW)
        let y = min(max(point.y, bounds.minY + halfH), bounds.maxY - halfH)
        return CGPoint(x: x, y: y)
    }
}
