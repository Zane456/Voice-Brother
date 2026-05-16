import AppKit

/// Programmatic vector status-bar icon — a speech bubble with 3 internal
/// waveform bars. Drawn as a template image so the system tints it black
/// in light menu bars and white in dark ones, matching neighbouring system
/// status items (Wi-Fi, battery).
///
/// The shape mirrors the app icon (bubble outline + #339CFF bars) but is
/// monochrome here because menu bars allow only template glyphs.
enum StatusBarIcon {

    /// Idle / ready state — full bubble with waveform bars inside.
    static func idle(size: CGFloat = 18) -> NSImage {
        renderBubble(size: size, accent: false)
    }

    /// Recording state — same bubble, but the centre bar is replaced by a
    /// solid dot (same visual idea as `record.circle.fill` but staying on-brand).
    /// Caller is responsible for tinting via `button.contentTintColor` if a
    /// non-template colour is wanted; by default it's a template so it goes
    /// black/white with the menu bar.
    static func recording(size: CGFloat = 18) -> NSImage {
        renderBubble(size: size, accent: true)
    }

    private static func renderBubble(size s: CGFloat, accent: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            let stroke: CGFloat = max(1.2, s * 0.085)

            // Bubble body — squircle-ish oval that leaves room for the tail
            // at lower-left and a small bottom margin.
            let bubbleInset: CGFloat = stroke
            let tailSize: CGFloat = s * 0.18
            let bubbleRect = NSRect(
                x: bubbleInset,
                y: tailSize * 0.6,
                width: s - bubbleInset * 2,
                height: s - tailSize * 0.6 - bubbleInset
            )
            let bubble = NSBezierPath(ovalIn: bubbleRect)
            bubble.lineWidth = stroke
            bubble.lineJoinStyle = .round
            NSColor.black.setStroke()
            bubble.stroke()

            // Tail — small triangular peak protruding from the bubble's
            // lower-left, then filled in. Drawn on top of the bubble outline
            // and re-filled with white inside to "punch" the seam clean.
            let tailTopX = bubbleRect.minX + bubbleRect.width * 0.22
            let tailTopY = bubbleRect.minY + bubbleRect.height * 0.12
            let tailRightX = bubbleRect.minX + bubbleRect.width * 0.42
            let tailRightY = bubbleRect.minY + bubbleRect.height * 0.20
            let tailTip = NSPoint(x: bubbleInset * 0.5, y: bubbleInset * 0.5)

            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: tailTopX, y: tailTopY))
            tail.line(to: tailTip)
            tail.line(to: NSPoint(x: tailRightX, y: tailRightY))
            tail.lineWidth = stroke
            tail.lineJoinStyle = .round
            tail.lineCapStyle = .round
            tail.stroke()

            // Waveform bars — 3 vertical rounded rects, centre tallest.
            // In recording mode, replace the centre bar with a filled dot so
            // the icon reads "active" at 18 px without changing footprint.
            let barW: CGFloat = max(1.0, s * 0.10)
            let gap: CGFloat = max(1.0, s * 0.10)
            let cx = bubbleRect.midX
            let cy = bubbleRect.midY + s * 0.02

            let barHeights: [CGFloat] = [s * 0.20, s * 0.32, s * 0.20]
            for (i, h) in barHeights.enumerated() {
                let dx = CGFloat(i - 1) * (barW + gap)
                let isCentreInRecording = (accent && i == 1)
                if isCentreInRecording {
                    let r = barW * 1.2
                    let dotRect = NSRect(x: cx + dx - r, y: cy - r, width: r * 2, height: r * 2)
                    NSBezierPath(ovalIn: dotRect).fill()
                } else {
                    let barRect = NSRect(x: cx + dx - barW / 2, y: cy - h / 2, width: barW, height: h)
                    let path = NSBezierPath(roundedRect: barRect, xRadius: barW / 2, yRadius: barW / 2)
                    NSColor.black.setFill()
                    path.fill()
                }
            }

            return true
        }
        img.isTemplate = true
        return img
    }
}
