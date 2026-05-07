# Theme System Design Spec

## Goal

Add 4 switchable visual themes to Voice Bubble's General Settings. Pure visual layer change — no protocol/backend/functional changes.

## Themes

### 1. Bubble Blue (Default) — current look, unchanged

| Token | Value |
|-------|-------|
| `bgGradient` | `["E8F4FD","D6ECFA","E0DFF0","D8EAF5","E5F0F8"]` |
| `bubbleColors` | `[(160,190,255),(190,170,255),(150,220,230),(255,180,210),(170,210,255),(200,180,255),(160,230,220),(255,195,220)]` |
| `textPrimary` | `#2C3E6B` |
| `textSecondary` | `#8AA0BE` |
| `accent` | `#4ECDC4` |
| `accentSelected` | `#7B8CF5` |
| `cardFill` | `white 0.55` |
| `cardBorder` | `white 0.65` |
| `sidebarSelected` | `#D8E4F8` |
| `sidebarText` | `#3A4F6B` |

### 2. Midnight — dark mode

| Token | Value |
|-------|-------|
| `bgGradient` | `["0F0F1A","141425","1A1A2E","12121F"]` |
| `bubbleColors` | `[(74,58,138),(42,74,122),(42,106,106),(106,42,90),(58,74,138),(90,58,138),(42,122,106),(122,58,90)]` |
| `textPrimary` | `#E8E8F0` |
| `textSecondary` | `#7A7A9A` |
| `accent` | `#7C6AFF` |
| `accentSelected` | `#9B8AFF` |
| `cardFill` | `white 0.06` |
| `cardBorder` | `white 0.08` |
| `sidebarSelected` | `rgba(124,106,255,0.15)` |
| `sidebarText` | `#9A9AB0` |
| `sidebarMaterial` | `.ultraThinMaterial` (dark appearance) |

### 3. Sakura — warm pink

| Token | Value |
|-------|-------|
| `bgGradient` | `["FDF2F8","FCE7F3","F3E8FF","FFF1F2"]` |
| `bubbleColors` | `[(249,168,212),(196,181,253),(253,186,116),(253,164,175),(216,180,254),(252,165,165),(253,230,138),(167,243,208)]` |
| `textPrimary` | `#4A2040` |
| `textSecondary` | `#B07A9A` |
| `accent` | `#EC4899` |
| `accentSelected` | `#D946EF` |
| `cardFill` | `white 0.60` |
| `cardBorder` | `rgba(255,200,230,0.4)` |
| `sidebarSelected` | `#FCE7F3` |
| `sidebarText` | `#6B3A5B` |

### 4. Mint — fresh green

| Token | Value |
|-------|-------|
| `bgGradient` | `["ECFDF5","D1FAE5","E0F2FE","F0FDF4"]` |
| `bubbleColors` | `[(110,231,183),(52,211,153),(125,211,252),(253,224,71),(103,232,249),(134,239,172),(196,181,253),(252,211,77)]` |
| `textPrimary` | `#134E4A` |
| `textSecondary` | `#6B9A8A` |
| `accent` | `#10B981` |
| `accentSelected` | `#059669` |
| `cardFill` | `white 0.55` |
| `cardBorder` | `rgba(167,243,208,0.4)` |
| `sidebarSelected` | `#D1FAE5` |
| `sidebarText` | `#2D6B5A` |

## Architecture

### New file: `Shared/ThemeManager.swift`

```
@MainActor
final class ThemeManager: ObservableObject {
    @Published var current: AppTheme

    // Theme enum with all tokens
    enum AppTheme: String, CaseIterable, Codable {
        case bubbleBlue, midnight, sakura, mint
    }

    // Computed properties returning current theme's tokens
    var textPrimary: Color { ... }
    var textSecondary: Color { ... }
    var accent: Color { ... }
    var accentSelected: Color { ... }
    var bgGradientColors: [Color] { ... }
    var bubbleColors: [Color] { ... }
    var cardFillOpacity: Double { ... }
    var cardBorderColor: Color { ... }
    var sidebarSelectedBg: Color { ... }
    var sidebarText: Color { ... }
    var isDark: Bool { ... }  // true only for Midnight
}
```

### Config persistence

- Add `theme: String` to `AppConfig` (default: `"bubbleBlue"`)
- ThemeManager reads from AppConfig on init, writes on change

### Injection

- ThemeManager injected as `@EnvironmentObject` from App entry point alongside ConfigManager
- All views read from ThemeManager instead of hardcoded hex values

## Files to modify

| File | Change |
|------|--------|
| `Shared/AppConfig.swift` | Add `theme` property + save/load |
| **New** `Shared/ThemeManager.swift` | Theme enum + all token definitions |
| `VoiceBubbleApp.swift` (entry) | Create and inject ThemeManager |
| `Frontend/Components/GlassmorphismBackground.swift` | Read `bgGradientColors` + `bubbleColors` from ThemeManager |
| `Frontend/Components/ColorExtension.swift` | `glassCard()` reads theme tokens |
| `Frontend/Components/SectionHeader.swift` | Read `textPrimary` from theme |
| `Frontend/Components/CustomToggleStyle.swift` | Read `accent` from theme |
| `Frontend/MainWindow.swift` | Sidebar colors from theme |
| `Frontend/Tabs/Sections/GeneralSettingsSection.swift` | Add theme picker UI + all hardcoded colors → theme |
| `Frontend/Tabs/Sections/VoiceSettingsSection.swift` | Hardcoded colors → theme |
| `Frontend/Tabs/Sections/MeetingSettingsSection.swift` | Hardcoded colors → theme |
| `Frontend/Tabs/AboutTab.swift` | Hardcoded colors → theme |
| `Frontend/Components/RecordingOverlayPanel.swift` | Overlay colors from theme |
| `Frontend/Components/RecordingWaveformView.swift` | Waveform colors from theme |
| `Frontend/OnboardingView.swift` | Colors from theme |

## Theme Picker UI

In `GeneralSettingsSection`, above existing toggles:

```
SectionHeader("主题风格")

HStack(spacing: 16) {
    ForEach(AppTheme.allCases) { theme ->
        // 40x40 circle showing theme's gradient preview
        // Scale animation on tap (0.9 → 1.0)
        // Checkmark overlay on selected
        // Theme name label below
    }
}
.glassCard()
```

Each circle shows a 2-color diagonal gradient from the theme's first two bgGradient colors.

## Dark mode considerations (Midnight theme)

- `GlassmorphismBackground`: bubble opacity drops from 0.35 → 0.20 for core, glow stays at 0.12
- `glassCard()`: uses dark card fill + thinner border
- `.ultraThinMaterial` on sidebar adapts automatically via SwiftUI
- Glass highlight on bubbles: white opacity 0.55 → 0.15
- Bubble ring opacity: 0.3 → 0.15

## Not changed

- Protocol layer (`Protocols.swift`, `Types.swift`)
- Backend services (VoiceService, MeetingService, etc.)
- Any functionality or behavior
- RecordingOverlayPanel show/hide logic (only colors)
