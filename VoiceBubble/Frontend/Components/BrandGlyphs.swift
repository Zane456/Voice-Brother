import SwiftUI

/// On-brand vector glyph — a speech bubble with waveform bars inside, the same
/// motif as the app logo and `StatusBarIcon`. Used as the 语音输入 card badge.
///
/// Pure SwiftUI `Shape`s: scales crisply at any size and takes a single
/// `color`, so passing `theme.accent` makes it follow light/dark automatically
/// with no Asset Catalog entries.
///
/// Geometry is a direct translation of `StatusBarIcon.renderBubble` (authored
/// in AppKit bottom-left coordinates) into SwiftUI top-left space, so the two
/// stay visually consistent.
struct BrandGlyph: View {
    var color: Color
    var size: CGFloat

    var body: some View {
        ZStack {
            BubbleOutline()
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.085,
                                                  lineCap: .round,
                                                  lineJoin: .round))
            WaveformBars().fill(color)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Bubble

/// Speech-bubble outline: an ellipse body plus a small V-shaped tail poking
/// from the lower-left. Stroked (not filled) by the caller.
private struct BubbleOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        var p = Path()

        // Ellipse body — leaves a margin so the round stroke isn't clipped.
        let bubble = CGRect(x: s * 0.085, y: s * 0.085, width: s * 0.83, height: s * 0.807)
        p.addEllipse(in: bubble)

        // Tail — a V protruding from the bubble's lower-left toward the corner.
        p.move(to: CGPoint(x: s * 0.268, y: s * 0.795))
        p.addLine(to: CGPoint(x: s * 0.042, y: s * 0.958))
        p.addLine(to: CGPoint(x: s * 0.434, y: s * 0.731))
        return p
    }
}

// MARK: - Inner content

/// 3 vertical rounded bars, centre tallest — the logo's waveform motif.
private struct WaveformBars: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        var p = Path()

        let barW = s * 0.10
        let gap = s * 0.10
        let cx = s * 0.50
        let cy = s * 0.468
        let heights: [CGFloat] = [s * 0.20, s * 0.32, s * 0.20]

        for (i, h) in heights.enumerated() {
            let dx = CGFloat(i - 1) * (barW + gap)
            let bar = CGRect(x: cx + dx - barW / 2, y: cy - h / 2, width: barW, height: h)
            p.addRoundedRect(in: bar, cornerSize: CGSize(width: barW / 2, height: barW / 2))
        }
        return p
    }
}
