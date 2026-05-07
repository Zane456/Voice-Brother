import AppKit
import SwiftUI

// MARK: - Physics Bubble Model

private class PhysicsBubble: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var vx: CGFloat
    var vy: CGFloat
    let radius: CGFloat
    var color: Color
    let phase: CGFloat  // for breathing animation offset

    init(x: CGFloat, y: CGFloat, vx: CGFloat, vy: CGFloat,
         radius: CGFloat, color: Color, phase: CGFloat) {
        self.x = x
        self.y = y
        self.vx = vx
        self.vy = vy
        self.radius = radius
        self.color = color
        self.phase = phase
    }
}

// MARK: - GlassmorphismBackground

struct GlassmorphismBackground: View {
    @EnvironmentObject private var theme: ThemeManager

    @State private var bubbles: [PhysicsBubble] = []
    @State private var lastUpdate: Date = .now
    @State private var elapsed: Double = 0
    @State private var lastTheme: AppTheme?
    /// Tracks whether *any* app window is currently visible. When false, we
    /// pause the TimelineView so the 60–120Hz physics tick stops eating CPU
    /// while the user has the menu-bar app running with no window on screen.
    @State private var isWindowVisible: Bool = true

    // Physics constants
    private static let damping: CGFloat = 0.97
    private static let maxSpeed: CGFloat = 35.0
    private static let edgeSpring: CGFloat = 0.3
    private static let edgeMarginRatio: CGFloat = 0.08
    private static let repulsion: CGFloat = 0.4

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size

            TimelineView(.animation(paused: !isWindowVisible)) { timeline in
                let now = timeline.date
                Canvas { context, canvasSize in
                    drawBackground(context: context, size: canvasSize)
                    // Skip floating bubbles for minimal-decoration themes
                    // (Claude/Apple/OpenAI vibe). Those products keep the
                    // canvas quiet — drawing 8 colourful orbs over them
                    // would immediately undo the "clean" look.
                    if theme.decoration != .minimal {
                        drawBubbles(context: context, size: canvasSize)
                    }
                } symbols: {
                    // No symbols needed
                }
                .onChange(of: now) { newDate in
                    let dt = min(newDate.timeIntervalSince(lastUpdate), 1.0 / 30.0)
                    lastUpdate = newDate
                    elapsed += dt
                    updatePhysics(dt: CGFloat(dt), bounds: size)
                }
            }
            .onAppear {
                initBubbles(in: size)
                lastTheme = theme.current
            }
            .onChange(of: theme.current) { newTheme in
                // Re-color bubbles when theme changes
                let colors = theme.bubbleColors
                for (i, bubble) in bubbles.enumerated() {
                    bubble.color = colors[i % colors.count]
                }
                lastTheme = newTheme
            }
            // Pause physics when the main window is closed/hidden. For a
            // menu-bar app this is the common idle state — keeping a 60Hz
            // tick alive in the background just to update invisible bubbles
            // wastes CPU/GPU.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                isWindowVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
                isWindowVisible = NSApp.windows.contains { $0.isVisible && $0.canBecomeKey }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in
                isWindowVisible = false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { _ in
                isWindowVisible = true
            }
        }
    }

    // MARK: - Initialization

    private func initBubbles(in size: CGSize) {
        guard bubbles.isEmpty else { return }
        var rng = SeededRandomGenerator(seed: 42)
        let colors = theme.bubbleColors

        bubbles = (0..<8).map { i in
            let radius = CGFloat(45 + rng.next(in: 0..<55))
            return PhysicsBubble(
                x: CGFloat(rng.next(in: 60..<max(61, Int(size.width) - 60))),
                y: CGFloat(rng.next(in: 60..<max(61, Int(size.height) - 60))),
                vx: CGFloat(rng.next(in: -12..<12)),
                vy: CGFloat(rng.next(in: -12..<12)),
                radius: radius,
                color: colors[i % colors.count],
                phase: CGFloat(i) * 0.8
            )
        }
    }

    // MARK: - Physics Update

    private func updatePhysics(dt: CGFloat, bounds: CGSize) {
        let t = elapsed

        for bubble in bubbles {
            let p = Double(bubble.phase)

            // Layered sinusoidal drift — 3 frequencies so motion never repeats visibly
            let fx = sin(t * 0.47 + p * 2.1) * 0.6
                   + sin(t * 0.71 + p * 3.7) * 0.3
                   + sin(t * 1.13 + p * 0.9) * 0.1
            let fy = cos(t * 0.53 + p * 1.7) * 0.6
                   + cos(t * 0.83 + p * 2.9) * 0.3
                   + cos(t * 1.07 + p * 4.1) * 0.1

            // Target velocity from drift — this IS the velocity, not an acceleration
            // so bubbles always keep moving as long as time passes
            let targetVx = CGFloat(fx) * Self.maxSpeed
            let targetVy = CGFloat(fy) * Self.maxSpeed

            // Smooth blend toward target (acts like drag + force combined)
            let blend: CGFloat = 1.0 - pow(Self.damping, dt * 60.0)
            bubble.vx += (targetVx - bubble.vx) * blend
            bubble.vy += (targetVy - bubble.vy) * blend

            // Soft edge repulsion — spring force pushes away from boundaries
            let marginX = bounds.width * Self.edgeMarginRatio + bubble.radius
            let marginY = bounds.height * Self.edgeMarginRatio + bubble.radius

            if bubble.x < marginX {
                let penetration = (marginX - bubble.x) / marginX
                bubble.vx += penetration * Self.edgeSpring * Self.maxSpeed
            } else if bubble.x > bounds.width - marginX {
                let penetration = (bubble.x - (bounds.width - marginX)) / marginX
                bubble.vx -= penetration * Self.edgeSpring * Self.maxSpeed
            }
            if bubble.y < marginY {
                let penetration = (marginY - bubble.y) / marginY
                bubble.vy += penetration * Self.edgeSpring * Self.maxSpeed
            } else if bubble.y > bounds.height - marginY {
                let penetration = (bubble.y - (bounds.height - marginY)) / marginY
                bubble.vy -= penetration * Self.edgeSpring * Self.maxSpeed
            }

            // Position update
            bubble.x += bubble.vx * dt
            bubble.y += bubble.vy * dt

            // Hard clamp as safety net (should rarely trigger)
            bubble.x = max(0, min(bounds.width, bubble.x))
            bubble.y = max(0, min(bounds.height, bubble.y))
        }

        // Inter-bubble repulsion — push overlapping bubbles apart
        for i in 0..<bubbles.count {
            for j in (i + 1)..<bubbles.count {
                let a = bubbles[i]
                let b = bubbles[j]
                let dx = b.x - a.x
                let dy = b.y - a.y
                let dist = sqrt(dx * dx + dy * dy)
                let minDist = (a.radius + b.radius) * 1.6  // keep some gap between edges
                if dist < minDist && dist > 0.1 {
                    let overlap = (minDist - dist) / minDist
                    let force = overlap * Self.repulsion * Self.maxSpeed
                    let nx = dx / dist
                    let ny = dy / dist
                    a.vx -= nx * force
                    a.vy -= ny * force
                    b.vx += nx * force
                    b.vy += ny * force
                }
            }
        }
    }

    // MARK: - Drawing

    private func drawBackground(context: GraphicsContext, size: CGSize) {
        // Soft gradient base
        let gradient = Gradient(colors: theme.bgGradientColors)
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                gradient,
                startPoint: .zero,
                endPoint: CGPoint(x: size.width, y: size.height)
            )
        )
    }

    private func drawBubbles(context: GraphicsContext, size: CGSize) {
        let t = elapsed

        for bubble in bubbles {
            // Breathing: radius pulses ±12%
            let breathe = 1.0 + 0.12 * sin(t * 1.5 + Double(bubble.phase))
            let r = bubble.radius * CGFloat(breathe)

            let center = CGPoint(x: bubble.x, y: bubble.y)

            // Soft outer glow
            var glowCtx = context
            glowCtx.opacity = theme.bubbleGlowOpacity
            glowCtx.addFilter(.blur(radius: r * 0.8))
            let glowRect = CGRect(
                x: center.x - r * 1.4,
                y: center.y - r * 1.4,
                width: r * 2.8,
                height: r * 2.8
            )
            glowCtx.fill(
                Path(ellipseIn: glowRect),
                with: .color(bubble.color)
            )

            // Core body — radial gradient
            let coreRect = CGRect(
                x: center.x - r,
                y: center.y - r,
                width: r * 2,
                height: r * 2
            )
            context.fill(
                Path(ellipseIn: coreRect),
                with: .radialGradient(
                    Gradient(colors: [
                        bubble.color.opacity(theme.bubbleCoreOpacity),
                        bubble.color.opacity(theme.bubbleGlowOpacity),
                    ]),
                    center: center,
                    startRadius: 0,
                    endRadius: r
                )
            )

            // Glass highlight (top-left crescent)
            let highlightRect = CGRect(
                x: center.x - r * 0.5,
                y: center.y - r * 0.6,
                width: r * 0.6,
                height: r * 0.4
            )
            var highlightCtx = context
            highlightCtx.opacity = theme.bubbleHighlightOpacity
            highlightCtx.fill(
                Path(ellipseIn: highlightRect),
                with: .color(.white)
            )

            // Border ring — soap bubble edge
            var ringCtx = context
            ringCtx.opacity = theme.bubbleRingOpacity
            ringCtx.stroke(
                Path(ellipseIn: coreRect),
                with: .color(.white),
                lineWidth: 1.5
            )
        }
    }
}

// MARK: - Seeded Pseudo-Random Generator

private struct SeededRandomGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 1 : seed
    }

    mutating func next(in range: Range<Int>) -> Int {
        state = xorshift64(state)
        let count = range.count
        guard count > 0 else { return range.lowerBound }
        return Int(state % UInt64(count)) + range.lowerBound
    }

    private func xorshift64(_ x: UInt64) -> UInt64 {
        var y = x
        y ^= y << 13
        y ^= y >> 7
        y ^= y << 17
        return y
    }
}
