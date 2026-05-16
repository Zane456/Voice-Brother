import SwiftUI

/// "Speech bubble + waveform" mark — the in-app companion to `AppIcon.icns`.
///
/// Renders the asset-catalog `AppLogoMark` (which is the same artwork as the
/// dock icon, just with the white background replaced by transparent pixels)
/// at the requested size. Use anywhere the brand glyph should *be* the glyph
/// without a Dock-style tile around it: sidebar avatar, inline brand stamps,
/// onboarding hero, etc. The `.icns` is still authoritative for Dock /
/// Finder / Cmd+Tab.
struct AppLogoView: View {
    @EnvironmentObject private var theme: ThemeManager

    /// Side length in points. Defaults to a sidebar nav-icon size.
    let size: CGFloat

    /// Override the bubble outline colour. Currently unused — the asset is
    /// pre-rendered with the icon's near-black outline + Codex blue bars.
    /// Kept for API symmetry in case we add a tinted template variant.
    var outlineColor: Color? = nil

    /// Reserved, see above.
    var waveformColor: Color? = nil

    init(size: CGFloat = 22, outlineColor: Color? = nil, waveformColor: Color? = nil) {
        self.size = size
        self.outlineColor = outlineColor
        self.waveformColor = waveformColor
    }

    var body: some View {
        Image("AppLogoMark")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

/// Legacy/experimental Canvas implementation — not currently used. Kept in
/// case we want a tintable, fully template-able variant later (e.g. for a
/// monochrome onboarding placeholder). Detached from `AppLogoView.body` so
/// it doesn't pull in extra rendering work for every use site.
private struct AppLogoCanvas: View {
    @EnvironmentObject private var theme: ThemeManager
    let size: CGFloat
    let outlineColor: Color?
    let waveformColor: Color?

    var body: some View {
        let outline = outlineColor ?? theme.textPrimary
        let bars    = waveformColor ?? theme.accent

        Canvas { ctx, canvasSize in
            let s = min(canvasSize.width, canvasSize.height)
            // Stroke roughly 8% of side — same proportion as the app icon.
            let stroke = max(1.0, s * 0.085)

            // Bubble body — near-full circle, slight bottom margin to leave
            // room for the tail tip without clipping.
            let inset      = stroke * 0.6
            let tailReach  = s * 0.10                         // how far tail pokes
            let bubbleSide = s - inset * 2 - tailReach * 0.4  // square diameter
            let bubbleRect = CGRect(
                x: inset,
                y: inset,
                width:  bubbleSide,
                height: bubbleSide
            )

            var bubble = Path()
            bubble.addEllipse(in: bubbleRect)
            ctx.stroke(bubble, with: .color(outline),
                       style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))

            // Tail — a tiny triangular notch attached to the bubble's lower-
            // left perimeter. The two anchor points sit on the bubble outline,
            // and the tip extends just below+left of them. Stays close — the
            // earlier version drew a long pointer to the canvas corner.
            let bubbleCx = bubbleRect.midX
            let bubbleCy = bubbleRect.midY
            let radius   = bubbleSide / 2 - stroke / 2
            // Two points on the bubble at angles 200° and 240° (lower-left arc)
            func onBubble(deg: CGFloat) -> CGPoint {
                let a = deg * .pi / 180
                return CGPoint(x: bubbleCx + cos(a) * radius,
                               y: bubbleCy + sin(a) * radius)
            }
            let anchorTop = onBubble(deg: 200)
            let anchorBot = onBubble(deg: 240)
            let tailTip = CGPoint(
                x: bubbleRect.minX + bubbleRect.width * 0.05,
                y: bubbleRect.maxY + tailReach * 0.6
            )

            var tail = Path()
            tail.move(to: anchorTop)
            tail.addLine(to: tailTip)
            tail.addLine(to: anchorBot)
            ctx.stroke(tail, with: .color(outline),
                       style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))

            // Waveform — 5 rounded vertical bars, tallest in the middle.
            let barW = max(1.0, s * 0.07)
            let gap  = max(1.0, s * 0.07)
            let cx = bubbleRect.midX
            let cy = bubbleRect.midY

            let heights: [CGFloat] = [0.30, 0.50, 0.66, 0.50, 0.30]
            for (i, h) in heights.enumerated() {
                let dx = CGFloat(i - 2) * (barW + gap)
                let height = bubbleRect.height * h
                let rect = CGRect(x: cx + dx - barW / 2,
                                  y: cy - height / 2,
                                  width: barW,
                                  height: height)
                let path = Path(roundedRect: rect, cornerRadius: barW / 2)
                ctx.fill(path, with: .color(bars))
            }
        }
        .frame(width: size, height: size)
    }
}
