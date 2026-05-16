import SwiftUI
import AppKit
import Combine

// MARK: - Theme Enum

enum AppTheme: String, CaseIterable, Codable, Identifiable {
    case system   // Follows NSApp.effectiveAppearance (default)
    case light
    case dark

    var id: String { rawValue }

    static var selectableCases: [AppTheme] { [.system, .light, .dark] }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }

    var pickerSwatch: Color {
        switch self {
        case .system: return Color(hex: "FFFFFF")
        case .light:  return Color(hex: "FFFFFF")
        case .dark:   return Color(hex: "181818")
        }
    }

    var previewColors: [Color] {
        switch self {
        case .system: return [Color(hex: "FFFFFF"), Color(hex: "181818")]
        case .light:  return [Color(hex: "FFFFFF"), Color(hex: "339CFF")]
        case .dark:   return [Color(hex: "181818"), Color(hex: "339CFF")]
        }
    }
}

// MARK: - CardDepth (legacy; Codex is always flat)

enum CardDepth: Int, CaseIterable, Identifiable {
    case flat = 0

    var id: Int { rawValue }
    var displayName: String { "扁平" }
    var shadowRadius: CGFloat { 0 }
    var shadowOpacity: Double { 0 }
    var borderScale: Double { 1 }
}

// MARK: - ThemeManager

final class ThemeManager: ObservableObject {

    @Published var current: AppTheme {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: "appTheme")
            recomputeIsDark()
        }
    }

    @Published var cardDepth: CardDepth = .flat {
        didSet { UserDefaults.standard.set(cardDepth.rawValue, forKey: "cardDepth") }
    }

    /// Effective dark/light, computed from `current` + system appearance.
    @Published private(set) var isDark: Bool = false

    private var appearanceObserver: NSKeyValueObservation?

    init() {
        // Migrate any legacy theme key (e.g. "codex") to .system so existing
        // users get the new default automatically.
        if let raw = UserDefaults.standard.string(forKey: "appTheme"),
           let theme = AppTheme(rawValue: raw) {
            self.current = theme
        } else {
            self.current = .system
        }
        self.cardDepth = .flat
        recomputeIsDark()
        observeSystemAppearance()
    }

    deinit {
        appearanceObserver?.invalidate()
    }

    private func observeSystemAppearance() {
        let app = NSApplication.shared
        appearanceObserver = app.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.recomputeIsDark() }
        }
    }

    private func recomputeIsDark() {
        let newValue: Bool
        switch current {
        case .light: newValue = false
        case .dark:  newValue = true
        case .system:
            let appearance = NSApplication.shared.effectiveAppearance
            newValue = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        if newValue != isDark {
            isDark = newValue
        }
    }

    // MARK: - Base scale

    private func gray0()    -> Color { Color(hex: "FFFFFF") }
    private func gray50()   -> Color { Color(hex: "F9F9F9") }
    private func gray100()  -> Color { Color(hex: "EDEDED") }
    private func gray300()  -> Color { Color(hex: "AFAFAF") }
    private func gray500()  -> Color { Color(hex: "5D5D5D") }
    private func gray700()  -> Color { Color(hex: "303030") }
    private func gray750()  -> Color { Color(hex: "282828") }
    private func gray800()  -> Color { Color(hex: "212121") }
    private func gray900()  -> Color { Color(hex: "181818") }
    private func gray1000() -> Color { Color(hex: "0D0D0D") }

    private func blue50()   -> Color { Color(hex: "E5F3FF") }
    private func blue100()  -> Color { Color(hex: "99CEFF") }
    private func blue300()  -> Color { Color(hex: "339CFF") }
    private func blue900()  -> Color { Color(hex: "00284D") }

    // MARK: - Surfaces

    var windowBackground: Color   { isDark ? gray900() : gray0() }
    var contentBackground: Color  { isDark ? gray900() : gray0() }
    var surfaceBackground: Color  { isDark ? gray750() : gray0() }   // cards
    var sidebarBackground: Color  { isDark ? Color(hex: "121212") : gray50() }
    var inputBackground: Color    { isDark ? gray800() : gray0() }
    var tagBackground: Color      { isDark ? Color(white: 1, opacity: 0.06) : Color(white: 0, opacity: 0.05) }

    // MARK: - Borders

    /// Default hairline — 8% of the foreground color.
    var border: Color       { foreground(opacity: 0.08) }
    var borderLight: Color  { foreground(opacity: 0.04) }
    var borderHeavy: Color  { foreground(opacity: isDark ? 0.16 : 0.12) }
    var cardBorderColor: Color { border }

    // MARK: - Text

    var textPrimary: Color   { isDark ? Color.white : Color(hex: "1A1C1F") }
    var textSecondary: Color { textPrimary.opacity(0.70) }
    var textTertiary: Color  { textPrimary.opacity(0.50) }
    var textPlaceholder: Color { gray300() }

    // MARK: - Accent

    /// Codex brand blue. Used for focus, selection state, icon-accent, links.
    /// NOT used as primary-button fill — that's `textPrimary`.
    var accent: Color          { blue300() }
    var accentSecondary: Color { blue300() }

    // MARK: - Sidebar selection

    var sidebarSelectedBg: Color { isDark ? blue900() : blue50() }
    var sidebarText: Color { textSecondary }

    // MARK: - Semantic

    // Palette is restricted to blue / black / white / gray. Status is conveyed
    // by icon + copy, not hue — so warning & destructive both resolve to the
    // foreground color, and success reuses the brand blue.
    var warning: Color            { textPrimary }
    var warningBackground: Color  { warning.opacity(0.10) }
    var warningBorder: Color      { warning.opacity(0.25) }

    var destructive: Color           { textPrimary }
    var destructiveBackground: Color { destructive.opacity(0.10) }
    var stop: Color                  { destructive }

    var success: Color           { accent }
    var successBackground: Color { success.opacity(0.10) }

    var learningOrange: Color     { warning }
    var learningBackground: Color { warning.opacity(0.10) }
    var learningBorder: Color     { warning.opacity(0.25) }

    // Provenance badges — Codex pattern: distinguish via icon, not colour.
    var cloudBadge: Color { textTertiary }
    var localBadge: Color { textTertiary }

    // MARK: - Card surface (for glassCard())

    var cardOverlayColor: Color   { surfaceBackground }
    var cardFillOpacity: Double   { 1.0 }
    var cardMaterial: Material    { .regularMaterial }  // unused; kept for API compat
    var cardBaseCornerRadius: CGFloat { radiusLg }
    var cardBorderWidth: CGFloat  { 1.0 }
    var cardShadowRadius: CGFloat { 0 }
    var cardShadowOpacity: Double { 0 }

    // MARK: - Toggle

    /// Off-state track — muted gray that reads in both light & dark.
    var toggleInactive: Color { textPrimary.opacity(0.20) }
    /// On-state track — Codex uses the primary-button fill (always near-black
    /// in both light & dark; in dark mode it's `gray-1000` which is darker
    /// than the window background, giving the toggle visible weight).
    var toggleActive: Color   { isDark ? gray1000() : textPrimary }

    // MARK: - Waveform (recording overlay)

    var waveformColor: Color     { accent }
    var waveformColorLow: Color  { accent.opacity(0.35) }
    var waveformColorHigh: Color { accent }

    // MARK: - Typography

    /// All UI chrome uses the system sans (SF Pro / PingFang SC).
    var fontDesign: Font.Design { .default }

    /// Digits no longer require a separate mono font. Call sites should use
    /// `.monospacedDigit()` modifier instead of `Font.Design.monospaced`.
    /// Kept as `.default` so any remaining reads don't switch the typeface.
    var digitFontDesign: Font.Design { .default }

    var bodyWeight: Font.Weight { .regular }

    // MARK: - Radius scale

    let radius2xs: CGFloat = 2
    let radiusXs:  CGFloat = 4
    let radiusSm:  CGFloat = 6
    let radiusMd:  CGFloat = 8
    let radiusLg:  CGFloat = 10
    let radiusXl:  CGFloat = 12
    let radius2xl: CGFloat = 16
    let radius3xl: CGFloat = 20

    // MARK: - Motion

    let durationBasic: Double   = 0.15
    let durationRelaxed: Double = 0.30

    /// Codex's signature ease-out — cubic-bezier(.19, 1, .22, 1).
    /// Use for entering states, hover-in, dropdown reveal.
    var easeEnter: Animation {
        .timingCurve(0.19, 1.0, 0.22, 1.0, duration: durationBasic)
    }

    /// Snappier exit curve — cubic-bezier(.65, 0, .4, 1).
    var easeExitSnappy: Animation {
        .timingCurve(0.65, 0.0, 0.4, 1.0, duration: durationBasic)
    }

    // MARK: - Picker swatch (kept for API compatibility)

    var pickerSwatch: Color   { surfaceBackground }
    var previewColors: [Color] { [surfaceBackground, accent] }

    enum PickerPreviewStyle { case sharpSquare }
    var pickerPreviewStyle: PickerPreviewStyle { .sharpSquare }
    var pickerDots: [Color] { [accent] }

    // MARK: - Helpers

    /// Foreground color at a given opacity — used for borders and overlays so
    /// the same token works in light & dark without hardcoding white/black.
    private func foreground(opacity: Double) -> Color {
        textPrimary.opacity(opacity)
    }
}
