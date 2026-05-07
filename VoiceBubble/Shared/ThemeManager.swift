import SwiftUI
import Combine

// MARK: - Theme Enum

enum AppTheme: String, CaseIterable, Codable, Identifiable {
    case bubbleBlue
    case sakura
    case mint
    case pureWhite
    case caramelBrown   // 焦糖棕 — warm amber accents on cream backgrounds
    case mistSilver     // 雾银灰 — neutral light grays + system blue accent
    case clearSky       // 晴空蓝 — Material-style multi-hue with blue lead
    case inkPine        // 墨松绿 — deep teal-green on near-white neutrals
    case midnight       // Deprecated — hidden from picker via `selectableCases` but case kept so existing code compiles.

    var id: String { rawValue }

    /// Themes shown in the picker, in display order. Grouped by colour family
    /// so similar hues sit next to each other (blues together, greens
    /// together, etc.). Cases not listed here are kept on the enum only for
    /// migration — they no longer appear in the picker.
    ///   • bubbleBlue + clearSky (blues)
    ///   • mint + inkPine (greens)
    ///   • sakura (pink)
    ///   • caramelBrown (warm)
    /// `mistSilver` was removed — the swatch read as off-white rather than
    /// silver, so it didn't add a meaningful option.
    static var selectableCases: [AppTheme] {
        [.bubbleBlue, .clearSky, .mint, .sakura, .caramelBrown]
    }

    var displayName: String {
        switch self {
        // Renamed from 泡泡蓝 — the actual rendered colour is essentially
        // white with a cool moonlit tint, so describing it as "blue" misled
        // users about what they were picking.
        case .bubbleBlue:    return "月光白"
        case .midnight:      return "午夜紫"
        case .sakura:        return "樱花粉"
        case .mint:          return "薄荷绿"
        case .pureWhite:     return "极简白"
        case .caramelBrown:  return "焦糖棕"
        case .mistSilver:    return "雾银灰"
        case .clearSky:      return "晴空蓝"
        case .inkPine:       return "墨松绿"
        }
    }

    /// Solid colour shown in the appearance picker. **Not the brand accent —
    /// it's the theme's contentBackground pushed two shades deeper.** This
    /// way the swatch reads as "what the background will look like, slightly
    /// concentrated", matching the actual surface the user sees once they
    /// pick the theme. Earlier swatches used the saturated brand accent
    /// (e.g. #D97757 for caramelBrown) which had nothing to do with the
    /// pale cream background that theme actually paints.
    var pickerSwatch: Color {
        switch self {
        case .bubbleBlue:    return Color(hex: "DDE3EC")  // 月光白 — pale cool white-grey, deeper than its near-white bg
        case .midnight:      return Color(hex: "7C6AFF")
        case .sakura:        return Color(hex: "F2CDDD")  // bg FDF5F9 → deeper pink
        case .mint:          return Color(hex: "C4E8D4")  // bg F5FDF8 → deeper mint
        case .pureWhite:     return Color(hex: "E0E0E2")
        case .caramelBrown:  return Color(hex: "EDDDC0")  // bg FBF6EE → deeper cream
        case .mistSilver:    return Color(hex: "C8CDD5")
        case .clearSky:      return Color(hex: "B5D2F5")  // bg E1EEFD → deeper sky blue
        case .inkPine:       return Color(hex: "9DCAA8")  // bg D8EEDD → deeper pine green
        }
    }

    var previewColors: [Color] {
        switch self {
        case .bubbleBlue:    return [Color(hex: "B8DAF5"), Color(hex: "C8CCE8")]
        case .midnight:      return [Color(hex: "C4C4D8"), Color(hex: "B0B0C8")]
        case .sakura:        return [Color(hex: "FDF2F8"), Color(hex: "F8F0FF")]
        case .mint:          return [Color(hex: "E4FAF0"), Color(hex: "E8F5FD")]
        case .pureWhite:     return [Color(hex: "FFFFFF"), Color(hex: "F8F8F8")]
        case .caramelBrown:  return [Color(hex: "F2DCC0"), Color(hex: "D97757")]
        case .mistSilver:    return [Color(hex: "F5F5F7"), Color(hex: "C7C7CC")]
        case .clearSky:      return [Color(hex: "D2E3FC"), Color(hex: "4285F4")]
        case .inkPine:       return [Color(hex: "E0F2EC"), Color(hex: "10A37F")]
        }
    }
}

// MARK: - ThemeManager

/// User-controlled card elevation — independent of theme. Four discrete
/// steps so the picker can render as a segmented control.
///
/// Old cases `medium` (=3) and `deep` (=4) were removed because the heavier
/// shadows didn't fit any of the supported themes. A `bare` step was added
/// at the bottom for users who want even less chrome than `flat` —
/// `bare` removes the card border entirely, leaving only the fill.
enum CardDepth: Int, CaseIterable, Identifiable {
    case bare = -1     // no border, no shadow — pure fill
    case flat = 0      // hairline border, no shadow
    case whisper = 1   // hairline border, faint shadow
    case soft = 2      // default — full border, soft shadow

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .bare:    return "无"
        case .flat:    return "扁平"
        case .whisper: return "微"
        case .soft:    return "标准"
        }
    }

    /// SwiftUI shadow radius.
    var shadowRadius: CGFloat {
        switch self {
        case .bare, .flat: return 0
        case .whisper:     return 4
        case .soft:        return 8
        }
    }

    /// Drop-shadow opacity. Pairs with shadowRadius to feel proportional.
    var shadowOpacity: Double {
        switch self {
        case .bare, .flat: return 0
        case .whisper:     return 0.04
        case .soft:        return 0.06
        }
    }

    /// Multiplier applied to a card's stroke width. `bare` zeroes it out so
    /// the border vanishes entirely; everything else keeps the theme's
    /// configured border.
    var borderScale: Double {
        switch self {
        case .bare:                          return 0
        case .flat, .whisper, .soft:         return 1
        }
    }
}

final class ThemeManager: ObservableObject {

    @Published var current: AppTheme {
        didSet { UserDefaults.standard.set(current.rawValue, forKey: "appTheme") }
    }

    /// User's chosen card elevation, applied on top of every theme. Lets a
    /// user keep e.g. the minimalist Claude-style theme but bump the cards
    /// to "deep" if they prefer more separation. Persists across launches.
    @Published var cardDepth: CardDepth {
        didSet { UserDefaults.standard.set(cardDepth.rawValue, forKey: "cardDepth") }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: "appTheme"),
           let theme = AppTheme(rawValue: raw),
           theme != .midnight {  // Migrate users off the retired midnight theme.
            self.current = theme
        } else {
            self.current = .bubbleBlue
        }

        let storedDepth = UserDefaults.standard.object(forKey: "cardDepth") as? Int
        self.cardDepth = CardDepth(rawValue: storedDepth ?? CardDepth.soft.rawValue)
            ?? .soft
    }

    var isDark: Bool { current == .midnight }

    // MARK: - Text Colors

    var textPrimary: Color {
        switch current {
        case .bubbleBlue:    return Color(hex: "2C3E6B")
        case .midnight:      return Color(hex: "E8E8F0")
        case .sakura:        return Color(hex: "4A2040")
        case .mint:          return Color(hex: "134E4A")
        case .pureWhite:     return Color(hex: "1A1A1A")
        case .caramelBrown:  return Color(hex: "3C2A1E")
        case .mistSilver:    return Color(hex: "1D1D1F")
        case .clearSky:      return Color(hex: "202124")
        case .inkPine:       return Color(hex: "202123")
        }
    }

    var textSecondary: Color {
        switch current {
        case .bubbleBlue:    return Color(hex: "5A7098")
        case .midnight:      return Color(hex: "9A9AB0")
        case .sakura:        return Color(hex: "7A4A6A")
        case .mint:          return Color(hex: "3A7A6A")
        case .pureWhite:     return Color(hex: "6B6B6B")
        case .caramelBrown:  return Color(hex: "6B4F3D")
        case .mistSilver:    return Color(hex: "515154")
        case .clearSky:      return Color(hex: "5F6368")
        case .inkPine:       return Color(hex: "565869")
        }
    }

    var textTertiary: Color {
        switch current {
        case .bubbleBlue:    return Color(hex: "8AA0BE")
        case .midnight:      return Color(hex: "7A7A9A")
        case .sakura:        return Color(hex: "B07A9A")
        case .mint:          return Color(hex: "6B9A8A")
        case .pureWhite:     return Color(hex: "999999")
        case .caramelBrown:  return Color(hex: "9C7E6A")
        case .mistSilver:    return Color(hex: "86868B")
        case .clearSky:      return Color(hex: "9AA0A6")
        case .inkPine:       return Color(hex: "8E8EA0")
        }
    }

    var textPlaceholder: Color {
        switch current {
        case .bubbleBlue:    return Color(hex: "C0CBDA")
        case .midnight:      return Color(hex: "5A5A7A")
        case .sakura:        return Color(hex: "D0A0C0")
        case .mint:          return Color(hex: "8ABAA8")
        case .pureWhite:     return Color(hex: "BBBBBB")
        case .caramelBrown:  return Color(hex: "C4A88E")
        case .mistSilver:    return Color(hex: "B0B0B5")
        case .clearSky:      return Color(hex: "BDC1C6")
        case .inkPine:       return Color(hex: "C5C5D2")
        }
    }

    // MARK: - Accent Colors

    var accent: Color {
        switch current {
        case .bubbleBlue:    return Color(hex: "4ECDC4")
        case .midnight:      return Color(hex: "7C6AFF")
        case .sakura:        return Color(hex: "EC4899")
        case .mint:          return Color(hex: "10B981")
        case .pureWhite:     return Color(hex: "007AFF")
        case .caramelBrown:  return Color(hex: "D97757")
        case .mistSilver:    return Color(hex: "007AFF")
        case .clearSky:      return Color(hex: "4285F4")
        case .inkPine:       return Color(hex: "10A37F")
        }
    }

    var accentSecondary: Color {
        switch current {
        case .bubbleBlue:    return Color(hex: "7B8CF5")
        case .midnight:      return Color(hex: "9B8AFF")
        case .sakura:        return Color(hex: "D946EF")
        case .mint:          return Color(hex: "059669")
        case .pureWhite:     return Color(hex: "007AFF")
        case .caramelBrown:  return Color(hex: "B85D3E")
        case .mistSilver:    return Color(hex: "5AC8FA")
        case .clearSky:      return Color(hex: "1A73E8")
        case .inkPine:       return Color(hex: "19C37D")
        }
    }

    // MARK: - Surface Colors

    var cardFillOpacity: Double {
        switch current {
        case .midnight:      return 0.06
        case .pureWhite:     return 0.88
        case .mistSilver:    return 0.82
        case .inkPine:       return 0.85
        default:             return 0.72
        }
    }

    var cardOverlayColor: Color { .white }

    var cardBorderColor: Color {
        switch current {
        case .bubbleBlue:    return Color.white.opacity(0.65)
        case .midnight:      return Color.white.opacity(0.08)
        case .sakura:        return Color(hex: "FFC8E6").opacity(0.4)
        case .mint:          return Color(hex: "A7F3D0").opacity(0.4)
        case .pureWhite:     return Color(hex: "E0E0E0").opacity(0.6)
        case .caramelBrown:  return Color(hex: "E8D4B8").opacity(0.55)
        case .mistSilver:    return Color(hex: "D2D2D7").opacity(0.6)
        case .clearSky:      return Color(hex: "DADCE0").opacity(0.6)
        case .inkPine:       return Color(hex: "D9D9E3").opacity(0.55)
        }
    }

    var inputBackground: Color {
        switch current {
        case .bubbleBlue:    return Color(hex: "F5F8FE")
        case .midnight:      return Color.white.opacity(0.05)
        case .sakura:        return Color(hex: "FFF5FA")
        case .mint:          return Color(hex: "F0FDF8")
        case .pureWhite:     return Color(hex: "F5F5F5")
        case .caramelBrown:  return Color(hex: "FAF4ED")
        case .mistSilver:    return Color(hex: "F5F5F7")
        case .clearSky:      return Color(hex: "F8F9FA")
        case .inkPine:       return Color(hex: "F7F7F8")
        }
    }

    var surfaceBackground: Color {
        switch current {
        case .bubbleBlue:    return Color(hex: "F2F6FC")
        case .midnight:      return Color.white.opacity(0.04)
        case .sakura:        return Color(hex: "FDF2F8")
        case .mint:          return Color(hex: "ECFDF5")
        case .pureWhite:     return Color(hex: "F8F8F8")
        case .caramelBrown:  return Color(hex: "F5EBDC")
        case .mistSilver:    return Color(hex: "FBFBFD")
        case .clearSky:      return Color(hex: "F1F3F4")
        case .inkPine:       return Color(hex: "FBFBFC")
        }
    }

    var tagBackground: Color {
        switch current {
        case .bubbleBlue:    return Color(hex: "EDF2F7")
        case .midnight:      return Color.white.opacity(0.08)
        case .sakura:        return Color(hex: "FCE7F3")
        case .mint:          return Color(hex: "D1FAE5")
        case .pureWhite:     return Color(hex: "EEEEEE")
        case .caramelBrown:  return Color(hex: "F0E0CC")
        case .mistSilver:    return Color(hex: "EBEBEF")
        case .clearSky:      return Color(hex: "E8F0FE")
        case .inkPine:       return Color(hex: "ECECF1")
        }
    }

    // MARK: - Border Colors

    var border: Color {
        switch current {
        case .bubbleBlue:    return Color(hex: "C8D8EA")
        case .midnight:      return Color.white.opacity(0.10)
        case .sakura:        return Color(hex: "F0C0D8")
        case .mint:          return Color(hex: "A0D8C0")
        case .pureWhite:     return Color(hex: "D8D8D8")
        case .caramelBrown:  return Color(hex: "E0CDB0")
        case .mistSilver:    return Color(hex: "D2D2D7")
        case .clearSky:      return Color(hex: "DADCE0")
        case .inkPine:       return Color(hex: "D9D9E3")
        }
    }

    var borderLight: Color {
        switch current {
        case .bubbleBlue:    return Color(hex: "C0D0E4")
        case .midnight:      return Color.white.opacity(0.06)
        case .sakura:        return Color(hex: "E8B0D0")
        case .mint:          return Color(hex: "90C8B0")
        case .pureWhite:     return Color(hex: "E0E0E0")
        case .caramelBrown:  return Color(hex: "EAD9BE")
        case .mistSilver:    return Color(hex: "E5E5EA")
        case .clearSky:      return Color(hex: "E8EAED")
        case .inkPine:       return Color(hex: "E5E5EA")
        }
    }

    // MARK: - Window Surface Colors

    /// Sidebar fill — must contrast visibly with contentBackground.
    /// Two rules depending on how saturated the content surface is:
    ///   • **Light/pale themes** (月光白, 樱花粉, 薄荷绿, 焦糖棕) → sidebar is
    ///     slightly *deeper* than content. Anchors the layout against pale
    ///     surfaces.
    ///   • **More-saturated themes** (晴空蓝, 墨松绿) → sidebar is *lighter*
    ///     (near-white with a hint of the theme hue). A deeper sidebar on
    ///     top of an already-coloured content surface looked heavy.
    var sidebarBackground: Color {
        switch current {
        case .bubbleBlue:    return Color(hex: "EAEEF4")  // slightly deeper cool grey than 月光白 bg
        case .midnight:      return Color(hex: "16162A")
        case .sakura:        return Color(hex: "FBF0F5")
        case .mint:          return Color(hex: "F0FAF5")
        case .pureWhite:     return Color(hex: "F5F5F5")
        case .caramelBrown:  return Color(hex: "F2EADC")  // softer than the old F0E2CF — still deeper than content
        case .mistSilver:    return Color(hex: "DCE0E8")
        case .clearSky:      return Color(hex: "E8F1FD")  // clearly blue — lighter than content E1EEFD but carries the sky-blue identity
        case .inkPine:       return Color(hex: "ECF7EF")  // lighter than content D8EEDD — fresh white-green
        }
    }

    /// Solid background fill for the tab content area. **Must visibly carry
    /// the theme's hue** — this layer sits on top of GlassmorphismBackground
    /// and is what the user mostly sees behind cards. If it's pure white,
    /// the theme name (墨松绿, 晴空蓝, etc.) doesn't match what's on screen.
    /// 樱花粉 works because it's `FDF5F9` — pale, but unmistakably pink.
    var contentBackground: Color {
        switch current {
        case .bubbleBlue:    return Color(hex: "F5F8FD")
        case .midnight:      return Color(hex: "0F0F1A")
        case .sakura:        return Color(hex: "FEFAFC")  // 樱花粉 — paler than FDF5F9, just a whisper of pink
        case .mint:          return Color(hex: "F5FDF8")
        case .pureWhite:     return Color(hex: "FFFFFF")
        case .caramelBrown:  return Color(hex: "FBF6EE")  // pale cream
        case .mistSilver:    return Color(hex: "EAEDF2")  // pale silver-blue, more visible than F2F5F8
        case .clearSky:      return Color(hex: "E1EEFD")  // pale sky-blue, more visible
        case .inkPine:       return Color(hex: "D8EEDD")  // pale pine-green, on par with 樱花粉's pink visibility
        }
    }

    // MARK: - Sidebar Colors

    var sidebarSelectedBg: Color {
        switch current {
        case .bubbleBlue:    return Color(hex: "D8E4F8")
        case .midnight:      return Color(hex: "7C6AFF").opacity(0.15)
        case .sakura:        return Color(hex: "FCE7F3")
        case .mint:          return Color(hex: "D1FAE5")
        case .pureWhite:     return Color(hex: "E8E8E8")
        case .caramelBrown:  return Color(hex: "EDD3B0")
        case .mistSilver:    return Color(hex: "E5E5EA")
        case .clearSky:      return Color(hex: "F2F7FE")  // lighter than sidebar bg E8F1FD — visible selected highlight
        case .inkPine:       return Color(hex: "ECF8F4")
        }
    }

    var sidebarText: Color {
        switch current {
        case .bubbleBlue:    return Color(hex: "3A4F6B")
        case .midnight:      return Color(hex: "9A9AB0")
        case .sakura:        return Color(hex: "6B3A5B")
        case .mint:          return Color(hex: "2D6B5A")
        case .pureWhite:     return Color(hex: "555555")
        case .caramelBrown:  return Color(hex: "5C4530")
        case .mistSilver:    return Color(hex: "3C3C43")
        case .clearSky:      return Color(hex: "3C4043")
        case .inkPine:       return Color(hex: "353740")
        }
    }

    // MARK: - Semantic Colors

    var warning: Color {
        switch current {
        case .midnight: return Color(hex: "E0A830")
        default:        return Color(hex: "C89828")
        }
    }

    var warningBackground: Color {
        switch current {
        case .midnight: return Color(hex: "C89828").opacity(0.12)
        default:        return Color(hex: "FFF8E7")
        }
    }

    var warningBorder: Color {
        switch current {
        case .midnight: return Color(hex: "C89828").opacity(0.25)
        default:        return Color(hex: "E8D08C")
        }
    }

    var destructive: Color { Color(hex: "FF6B8A") }

    var destructiveBackground: Color {
        switch current {
        case .midnight: return Color(hex: "FF6B8A").opacity(0.12)
        default:        return Color(hex: "FFF0F3")
        }
    }

    var stop: Color { Color(hex: "F4929E") }

    var learningOrange: Color {
        switch current {
        case .midnight: return Color(hex: "FFB840")
        default:        return Color(hex: "F5A623")
        }
    }

    var learningBackground: Color {
        switch current {
        case .midnight: return Color(hex: "F5A623").opacity(0.12)
        default:        return Color(hex: "FFFBF0")
        }
    }

    var learningBorder: Color {
        switch current {
        case .midnight: return Color(hex: "F5A623").opacity(0.25)
        default:        return Color(hex: "F0E0B0")
        }
    }

    var successBackground: Color {
        switch current {
        case .midnight: return accent.opacity(0.12)
        default:        return Color(hex: "EDFCFA")
        }
    }

    // MARK: - Background

    var bgGradientColors: [Color] {
        switch current {
        case .bubbleBlue:
            // 月光白 — near-white with the faintest cool-blue glaze so it
            // doesn't read as pure white but still feels overwhelmingly clean.
            return ["F8FAFC", "F2F5F9", "EFF3F8", "F2F5F9", "F8FAFC"].map { Color(hex: $0) }
        case .midnight:
            return ["0F0F1A", "141425", "1A1A2E", "12121F", "0F0F1A"].map { Color(hex: $0) }
        case .sakura:
            // Toned down — earlier values (FCE7F3, F3E8FF) read as candy
            // pink against the softer 樱花 brand. Now a gentler blossom whisper.
            return ["FEFAFC", "FDF3F7", "FBF0F5", "FEF6F8", "FEFAFC"].map { Color(hex: $0) }
        case .mint:
            return ["ECFDF5", "D1FAE5", "E0F2FE", "F0FDF4", "ECFDF5"].map { Color(hex: $0) }
        case .pureWhite:
            return ["FFFFFF", "FAFAFA", "F5F5F5", "FAFAFA", "FFFFFF"].map { Color(hex: $0) }
        case .caramelBrown:
            // Whisper-soft warm cream — Claude-style "paper warmth".
            return ["FBF7F0", "F8F2E8", "F5EEDF", "F8F2E8", "FBF7F0"].map { Color(hex: $0) }
        case .mistSilver:
            // True silvery white — slightly cool, the way a fogged silver
            // surface reads. Earlier values leaned neutral-gray; pulled the
            // hue toward a faint blue-silver and lightened so the name reads.
            return ["F2F4F7", "E8ECF2", "DCE3EB", "E5EAF0", "F2F4F7"].map { Color(hex: $0) }
        case .clearSky:
            // Pure sky-blue gradient — single hue, no Material multi-colour
            // wash. The name promises "晴空蓝" (clear sky blue), so the
            // background should literally look like a clear sky.
            return ["E3F0FE", "C8E0FB", "B5D5F8", "C8E0FB", "E3F0FE"].map { Color(hex: $0) }
        case .inkPine:
            // Must read unmistakably as pine green — the same way 樱花粉's
            // pink background reads obviously pink. Low-saturation greens
            // visually collapse to "off-white" quickly, so we need stronger
            // chroma than other themes use at this lightness.
            return ["D8ECDD", "B8DCC0", "92C89E", "B8DCC0", "D8ECDD"].map { Color(hex: $0) }
        }
    }

    var bubbleColors: [Color] {
        switch current {
        case .bubbleBlue:
            return [
                Color(red8: 160, green8: 190, blue8: 255),
                Color(red8: 190, green8: 170, blue8: 255),
                Color(red8: 150, green8: 220, blue8: 230),
                Color(red8: 255, green8: 180, blue8: 210),
                Color(red8: 170, green8: 210, blue8: 255),
                Color(red8: 200, green8: 180, blue8: 255),
                Color(red8: 160, green8: 230, blue8: 220),
                Color(red8: 255, green8: 195, blue8: 220),
            ]
        case .midnight:
            return [
                Color(red8: 74, green8: 58, blue8: 138),
                Color(red8: 42, green8: 74, blue8: 122),
                Color(red8: 42, green8: 106, blue8: 106),
                Color(red8: 106, green8: 42, blue8: 90),
                Color(red8: 58, green8: 74, blue8: 138),
                Color(red8: 90, green8: 58, blue8: 138),
                Color(red8: 42, green8: 122, blue8: 106),
                Color(red8: 122, green8: 58, blue8: 90),
            ]
        case .sakura:
            return [
                Color(red8: 249, green8: 168, blue8: 212),
                Color(red8: 196, green8: 181, blue8: 253),
                Color(red8: 253, green8: 186, blue8: 116),
                Color(red8: 253, green8: 164, blue8: 175),
                Color(red8: 216, green8: 180, blue8: 254),
                Color(red8: 252, green8: 165, blue8: 165),
                Color(red8: 253, green8: 230, blue8: 138),
                Color(red8: 167, green8: 243, blue8: 208),
            ]
        case .mint:
            return [
                Color(red8: 110, green8: 231, blue8: 183),
                Color(red8: 52, green8: 211, blue8: 153),
                Color(red8: 125, green8: 211, blue8: 252),
                Color(red8: 253, green8: 224, blue8: 71),
                Color(red8: 103, green8: 232, blue8: 249),
                Color(red8: 134, green8: 239, blue8: 172),
                Color(red8: 196, green8: 181, blue8: 253),
                Color(red8: 252, green8: 211, blue8: 77),
            ]
        case .pureWhite:
            return [
                Color(red8: 220, green8: 220, blue8: 225),
                Color(red8: 210, green8: 215, blue8: 225),
                Color(red8: 225, green8: 220, blue8: 220),
                Color(red8: 215, green8: 225, blue8: 220),
                Color(red8: 220, green8: 215, blue8: 230),
                Color(red8: 225, green8: 225, blue8: 215),
                Color(red8: 215, green8: 220, blue8: 228),
                Color(red8: 228, green8: 218, blue8: 222),
            ]
        case .caramelBrown:
            return [
                Color(red8: 217, green8: 119, blue8: 87),
                Color(red8: 232, green8: 163, blue8: 93),
                Color(red8: 245, green8: 200, blue8: 140),
                Color(red8: 222, green8: 167, blue8: 122),
                Color(red8: 200, green8: 142, blue8: 100),
                Color(red8: 240, green8: 188, blue8: 135),
                Color(red8: 215, green8: 175, blue8: 130),
                Color(red8: 230, green8: 205, blue8: 165),
            ]
        case .mistSilver:
            return [
                Color(red8: 198, green8: 215, blue8: 235),
                Color(red8: 210, green8: 215, blue8: 225),
                Color(red8: 220, green8: 225, blue8: 232),
                Color(red8: 175, green8: 200, blue8: 230),
                Color(red8: 215, green8: 220, blue8: 230),
                Color(red8: 200, green8: 210, blue8: 225),
                Color(red8: 188, green8: 205, blue8: 228),
                Color(red8: 222, green8: 228, blue8: 235),
            ]
        case .clearSky:
            return [
                Color(red8: 138, green8: 180, blue8: 248),  // Google blue
                Color(red8: 129, green8: 201, blue8: 149),  // Google green
                Color(red8: 242, green8: 153, blue8: 145),  // Google red
                Color(red8: 253, green8: 214, blue8: 99),   // Google yellow
                Color(red8: 165, green8: 200, blue8: 252),
                Color(red8: 158, green8: 220, blue8: 175),
                Color(red8: 248, green8: 178, blue8: 170),
                Color(red8: 252, green8: 220, blue8: 130),
            ]
        case .inkPine:
            return [
                Color(red8: 16, green8: 163, blue8: 127),
                Color(red8: 25, green8: 195, blue8: 125),
                Color(red8: 110, green8: 200, blue8: 175),
                Color(red8: 80, green8: 175, blue8: 155),
                Color(red8: 145, green8: 215, blue8: 195),
                Color(red8: 60, green8: 160, blue8: 130),
                Color(red8: 130, green8: 200, blue8: 180),
                Color(red8: 90, green8: 185, blue8: 160),
            ]
        }
    }

    // MARK: - Bubble Rendering Parameters

    var bubbleCoreOpacity: Double {
        switch current {
        case .midnight:      return 0.20
        case .pureWhite:     return 0.25
        case .mistSilver:    return 0.20
        case .inkPine:       return 0.18
        default:             return 0.35
        }
    }

    var bubbleGlowOpacity: Double {
        switch current {
        case .midnight:      return 0.08
        case .pureWhite:     return 0.06
        case .mistSilver:    return 0.05
        case .inkPine:       return 0.05
        default:             return 0.12
        }
    }

    var bubbleHighlightOpacity: Double {
        switch current {
        case .midnight:      return 0.15
        case .pureWhite:     return 0.70
        case .mistSilver:    return 0.65
        case .inkPine:       return 0.65
        default:             return 0.55
        }
    }

    var bubbleRingOpacity: Double {
        switch current {
        case .midnight:      return 0.15
        case .pureWhite:     return 0.20
        case .mistSilver:    return 0.18
        case .inkPine:       return 0.18
        default:             return 0.3
        }
    }

    // MARK: - Waveform

    var waveformColor: Color {
        switch current {
        case .bubbleBlue:    return Color(red: 0.25, green: 0.47, blue: 0.85)
        case .midnight:      return Color(hex: "9B8AFF")
        case .sakura:        return Color(hex: "EC4899")
        case .mint:          return Color(hex: "10B981")
        case .pureWhite:     return Color(hex: "007AFF")
        case .caramelBrown:  return Color(hex: "D97757")
        case .mistSilver:    return Color(hex: "007AFF")
        case .clearSky:      return Color(hex: "4285F4")
        case .inkPine:       return Color(hex: "10A37F")
        }
    }

    /// Bottom of waveform bar gradient (lighter / less prominent end).
    var waveformColorLow: Color { waveformColor.opacity(0.35) }

    /// Top of waveform bar gradient (saturated, high-energy end).
    var waveformColorHigh: Color { waveformColor.opacity(1.0) }

    // MARK: - Data Provenance Badges (cloud / local)

    /// Minimal-decoration themes (Claude / Apple / OpenAI) collapse cloud and
    /// local badges to a single neutral grey so the surface stays calm —
    /// distinguish them with the SF Symbol icon instead of colour.
    var cloudBadge: Color {
        switch current {
        case .bubbleBlue:    return Color(hex: "5B8DEF")
        case .midnight:      return Color(hex: "7C9AFF")
        case .sakura:        return Color(hex: "BD78F5")
        case .mint:          return Color(hex: "0EA5E9")
        case .pureWhite:     return Color(hex: "0A84FF")
        case .caramelBrown:  return Color(hex: "8A7765")  // warm neutral, not orange
        case .mistSilver:    return Color(hex: "8E8E93")  // system gray
        case .clearSky:      return Color(hex: "4285F4")
        case .inkPine:       return Color(hex: "8E8E93")
        }
    }

    var localBadge: Color {
        switch current {
        case .bubbleBlue:    return Color(hex: "4ECDC4")
        case .midnight:      return Color(hex: "5CD8C4")
        case .sakura:        return Color(hex: "EC4899")
        case .mint:          return Color(hex: "10B981")
        case .pureWhite:     return Color(hex: "30B96E")
        case .caramelBrown:  return Color(hex: "8A7765")  // same neutral — icon distinguishes
        case .mistSilver:    return Color(hex: "8E8E93")
        case .clearSky:      return Color(hex: "34A853")
        case .inkPine:       return Color(hex: "8E8E93")
        }
    }

    // MARK: - Decoration Intensity

    /// How much visual decoration the theme allows. Brand themes inspired by
    /// minimalist products (Claude, Apple, OpenAI) need to suppress the
    /// floating-bubble background, multi-coloured badges and frosted-glass
    /// cards that the original "expressive" themes lean into. Without this
    /// switch every theme inherits the same decorative language and ends up
    /// looking like the same app with different colours.
    enum Decoration {
        case expressive   // floating bubbles, frosted glass, multi-colour badges (bubbleBlue / sakura / mint)
        case minimal      // near-flat surface, no bubbles, monochrome badges (Claude / Apple / OpenAI)
        case material     // Google Material 3 — elevation shadows, multi-colour wash background
    }

    var decoration: Decoration {
        switch current {
        case .bubbleBlue, .sakura, .mint, .midnight, .pureWhite:
            return .expressive
        case .clearSky:
            return .material
        case .caramelBrown, .mistSilver, .inkPine:
            return .minimal
        }
    }

    // MARK: - Theme Personality (font / card / picker style)

    /// System font design used across the app — set on the root view via
    /// `.fontDesign(theme.fontDesign)` so all `Font.system(...)` text inherits it.
    ///
    /// Reality check (verified from real brand surfaces, not memory):
    /// Apple → SF Pro, Google → Google Sans / Roboto, OpenAI → OpenAI Sans /
    /// Inter, Anthropic Claude UI → Söhne (English) + PingFang SC (Chinese).
    /// **All four UIs are sans-serif**. SwiftUI's `.fontDesign` only has 4
    /// options (default / serif / rounded / monospaced), so:
    ///   • All four brand-inspired themes use `.default`. SF Pro (English)
    ///     and PingFang SC (Chinese) are what these brands actually render
    ///     on macOS — picking `.serif` would have substituted PingFang for
    ///     **Songti** (traditional Chinese serif with brush strokes), which
    ///     is the opposite of every modern AI product's house style.
    ///   • Differentiation between brand-themes lives in card material,
    ///     corner radius, border weight, shadow profile, and colour — not
    ///     typeface (impossible to do without bundling Söhne / Roboto /
    ///     OpenAI Sans as TTFs).
    ///   • sakura → `.serif`, mint → `.rounded` are kept as decorative
    ///     non-brand choices for the original three.
    /// Locked to `.default` for **every** theme so Chinese text always renders
    /// in PingFang SC (the system Chinese sans, also what Claude/Apple/Google/
    /// OpenAI use). `.serif` would have substituted Songti (traditional brush
    /// strokes) for Chinese, `.rounded` would have lost the Chinese cascade
    /// entirely — both look completely off in a Chinese-first interface.
    /// English text in all themes therefore renders in SF Pro. Theme
    /// personality is carried by colour, decoration intensity, card style
    /// and corner radius, not by typeface.
    var fontDesign: Font.Design {
        return .default
    }

    /// Font used for "technical" elements (timers, durations, monospaced digits).
    /// Lets the OpenAI-inspired theme keep its mono accent on numerals only,
    /// without forcing every paragraph into a monospaced font.
    var digitFontDesign: Font.Design {
        switch current {
        case .inkPine:  return .monospaced     // ChatGPT-style: code/digits in mono
        default:        return fontDesign
        }
    }

    /// Body text weight per theme — Google uses Medium for emphasis at
    /// smaller sizes, Apple uses Regular by default, etc.
    var bodyWeight: Font.Weight {
        switch current {
        case .clearSky:  return .medium       // Material 3 emphasis
        default:         return .regular
        }
    }

    /// Default corner radius for `.glassCard()` callers that don't specify one.
    /// Different aesthetics call for different roundness — Material 3 likes large
    /// radii, OpenAI/technical lean sharp.
    var cardBaseCornerRadius: CGFloat {
        switch current {
        case .bubbleBlue:    return 12
        case .midnight:      return 12
        case .sakura:        return 14
        case .mint:          return 12
        case .pureWhite:     return 12
        case .caramelBrown:  return 16   // paperish, soft
        case .mistSilver:    return 10   // crisp Apple
        case .clearSky:      return 18   // Material 3 large
        case .inkPine:       return 6    // sharp, technical
        }
    }

    /// Material used as the base fill for `.glassCard()`. Some aesthetics want
    /// a more solid, paper-like surface (`.regularMaterial`) instead of the
    /// translucent `.ultraThinMaterial` everyone else uses.
    var cardMaterial: Material {
        switch current {
        case .caramelBrown:  return .regularMaterial   // paper feel
        case .clearSky:      return .regularMaterial   // Material elevation surface
        case .inkPine:       return .thinMaterial      // light frost over white
        default:             return .ultraThinMaterial
        }
    }

    /// Stroke width for `.glassCard()` border. Material design uses 0 (no border,
    /// elevation does the work). OpenAI/technical aesthetic uses a heavier 1pt
    /// for clear "card" boundaries.
    var cardBorderWidth: CGFloat {
        switch current {
        case .clearSky:      return 0     // elevation, not borders
        case .caramelBrown:  return 0     // paper, no harsh outlines
        case .inkPine:       return 1.0   // technical/grid feel
        default:             return 0.5
        }
    }

    /// Drop-shadow profile per theme — Material/Google leans into elevation,
    /// Apple stays whisper-soft, OpenAI almost flat.
    var cardShadowRadius: CGFloat {
        switch current {
        case .clearSky:      return 12    // Material elevation
        case .caramelBrown:  return 6     // soft warm shadow
        case .mistSilver:    return 4     // Apple subtle
        case .inkPine:       return 2     // nearly flat
        default:             return 8
        }
    }

    var cardShadowOpacity: Double {
        switch current {
        case .clearSky:      return 0.10
        case .caramelBrown:  return 0.06
        case .inkPine:       return 0.03
        case .mistSilver:    return 0.04
        default:             return 0.05
        }
    }

    /// Style of the small color disc shown in the appearance picker.
    /// Each theme gets a discriminator that matches its overall personality so
    /// the eight options don't all look identical.
    enum PickerPreviewStyle {
        case gradient           // soft 2-color circle (default)
        case warmDisc           // solid warm circle + hairline ring (paper)
        case crispGlass         // gradient + crisp 1pt ring (Apple)
        case materialDots       // 4 small color dots (Google)
        case sharpSquare        // rounded square + solid color (OpenAI/grid)
    }

    var pickerPreviewStyle: PickerPreviewStyle {
        switch current {
        case .caramelBrown:  return .warmDisc
        case .mistSilver:    return .crispGlass
        case .clearSky:      return .materialDots
        case .inkPine:       return .sharpSquare
        default:             return .gradient
        }
    }

    /// Multi-color set used by themes whose picker preview shows several dots
    /// (currently just `clearSky`). Order matches Google's brand sequence.
    var pickerDots: [Color] {
        switch current {
        case .clearSky:
            return [Color(hex: "4285F4"), Color(hex: "EA4335"),
                    Color(hex: "FBBC04"), Color(hex: "34A853")]
        default:
            return current.previewColors
        }
    }

    // MARK: - Toggle inactive track

    var toggleInactive: Color {
        switch current {
        case .midnight:      return Color.white.opacity(0.15)
        case .pureWhite:     return Color(hex: "D0D0D0")
        case .caramelBrown:  return Color(hex: "E0CDB0")
        case .mistSilver:    return Color(hex: "D2D2D7")
        case .clearSky:      return Color(hex: "DADCE0")
        case .inkPine:       return Color(hex: "D9D9E3")
        default:             return Color(hex: "C8D8EA")
        }
    }
}
