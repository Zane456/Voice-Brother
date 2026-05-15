import SwiftUI
import Combine

// MARK: - Theme Enum (single case, abstraction kept for forward-compat)

enum AppTheme: String, CaseIterable, Codable, Identifiable {
    case codex

    var id: String { rawValue }

    /// Themes shown in the appearance picker. Currently just Codex —
    /// the picker UI is removed (see AboutTab cleanup), so this is
    /// retained only for forward-compatibility if a second theme ships.
    static var selectableCases: [AppTheme] { [.codex] }

    var displayName: String { "Codex" }

    var pickerSwatch: Color { Color(hex: "202123") }

    var previewColors: [Color] { [Color(hex: "202123"), Color(hex: "10A37F")] }
}

// MARK: - CardDepth (single value, kept for API compatibility)

enum CardDepth: Int, CaseIterable, Identifiable {
    case flat = 0   // Codex is flat by default — no shadows, hairline only.

    var id: Int { rawValue }
    var displayName: String { "扁平" }
    var shadowRadius: CGFloat { 0 }
    var shadowOpacity: Double { 0 }
    var borderScale: Double { 1 }
}

// MARK: - ThemeManager

/// Central design-token source. After the Codex redesign this only emits one
/// palette, but the abstraction is kept so call sites (`@EnvironmentObject
/// theme: ThemeManager`) don't have to change and a future second theme can
/// be added without rewriting every view.
final class ThemeManager: ObservableObject {

    @Published var current: AppTheme = .codex {
        didSet { UserDefaults.standard.set(current.rawValue, forKey: "appTheme") }
    }

    @Published var cardDepth: CardDepth = .flat {
        didSet { UserDefaults.standard.set(cardDepth.rawValue, forKey: "cardDepth") }
    }

    init() {
        // Migrate old users away from removed themes (sakura/mint/etc.) —
        // any non-codex stored value silently maps to .codex.
        if let raw = UserDefaults.standard.string(forKey: "appTheme"),
           let theme = AppTheme(rawValue: raw) {
            self.current = theme
        } else {
            self.current = .codex
        }
        // cardDepth migrates similarly: only .flat exists now.
        self.cardDepth = .flat
    }

    /// Always true — Codex is dark-first. Retained for any view that branches
    /// on isDark (e.g. status bar icon template flag).
    var isDark: Bool { true }

    // MARK: - Codex Brand Tokens (spec §5.1)

    // Surfaces
    var windowBackground:   Color { Color(hex: "0E0F12") }
    var contentBackground:  Color { Color(hex: "0E0F12") }
    var surfaceBackground:  Color { Color(hex: "202123") }
    var sidebarBackground:  Color { Color(hex: "202123") }
    var inputBackground:    Color { Color(hex: "1A1B1E") }
    var tagBackground:      Color { Color(hex: "2A2C30") }

    // Borders
    var border:             Color { Color(hex: "40434A") }
    var borderLight:        Color { Color(hex: "2E3036") }
    var cardBorderColor:    Color { Color(hex: "40434A") }

    // Text
    var textPrimary:        Color { Color(hex: "F5F7FA") }
    var textSecondary:      Color { Color(hex: "C5C7CD") }
    var textTertiary:       Color { Color(hex: "9EA1AA") }
    var textPlaceholder:    Color { Color(hex: "6B6E76") }

    // Accents
    var accent:             Color { Color(hex: "10A37F") }
    var accentSecondary:    Color { Color(hex: "2B8FFF") }

    // Sidebar selection
    var sidebarSelectedBg:  Color { accent.opacity(0.15) }
    var sidebarText:        Color { Color(hex: "C5C7CD") }

    // Semantic
    var warning:                Color { Color(hex: "F5A623") }
    var warningBackground:      Color { warning.opacity(0.12) }
    var warningBorder:          Color { warning.opacity(0.30) }
    var destructive:            Color { Color(hex: "EF4444") }
    var destructiveBackground:  Color { destructive.opacity(0.12) }
    var stop:                   Color { destructive }
    var learningOrange:         Color { warning }
    var learningBackground:     Color { warning.opacity(0.10) }
    var learningBorder:         Color { warning.opacity(0.25) }
    var successBackground:      Color { accent.opacity(0.12) }

    // Provenance badges — Codex pattern: distinguish via icon, not colour.
    var cloudBadge:         Color { textTertiary }
    var localBadge:         Color { textTertiary }

    // Card surface for `glassCard()` modifier
    var cardOverlayColor:   Color { surfaceBackground }
    var cardFillOpacity:    Double { 1.0 }
    var cardMaterial:       Material { .regularMaterial }   // unused by simplified modifier; kept for API compat
    var cardBaseCornerRadius: CGFloat { 8 }
    var cardBorderWidth:    CGFloat { 1.0 }
    var cardShadowRadius:   CGFloat { 0 }
    var cardShadowOpacity:  Double { 0 }

    // Toggle
    var toggleInactive:     Color { border }

    // Waveform (recording overlay)
    var waveformColor:      Color { accent }
    var waveformColorLow:   Color { accent.opacity(0.35) }
    var waveformColorHigh:  Color { accent }

    // MARK: - Typography

    /// Always system default (SF Pro on macOS / PingFang SC for Chinese).
    var fontDesign:      Font.Design { .default }

    /// Codex uses mono for digits/timers — keep this hook so existing call
    /// sites that read `theme.digitFontDesign` still get the right answer.
    var digitFontDesign: Font.Design { .monospaced }

    var bodyWeight:      Font.Weight { .regular }

    // MARK: - Picker swatch (unused now — picker is removed)

    var pickerSwatch: Color { surfaceBackground }
    var previewColors: [Color] { [surfaceBackground, accent] }

    enum PickerPreviewStyle { case sharpSquare }
    var pickerPreviewStyle: PickerPreviewStyle { .sharpSquare }
    var pickerDots: [Color] { [accent] }
}
