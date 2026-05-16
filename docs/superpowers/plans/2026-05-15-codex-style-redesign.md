# Codex Style Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Voice Bubble's current Glassmorphism + multi-theme look with a single OpenAI Codex Mac-app style (dark, hairline, mono accents, OpenAI green).

**Architecture:** Keep the existing `ThemeManager` abstraction as the single source of design tokens, but collapse `AppTheme` to one case (`.codex`) and replace every token's value with the Codex brand palette documented in the spec. Delete the animated `GlassmorphismBackground`. Simplify `glassCard()` to one rendering branch (sharp corner, hairline border, flat fill, no shadow). Add three small new components: `Spacing`, `Text.mono()`, `CodexButtonStyles`, `CodexBadge`. Rewrite `RecordingOverlayPanel` to a dark capsule with green waveform + mono "REC". Touch every Tab/Section file lightly to switch button styles, swap mono labels in, and remove the appearance picker UI.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit (NSPanel for overlay, NSStatusItem for menu bar), macOS 14+. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-05-15-codex-style-redesign-design.md`

---

## Conventions used in this plan

- **Build + restart**: Every task ends with the standard cycle from `CLAUDE.md`:
  ```bash
  xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet \
    && pkill -x "VoiceBubble" 2>/dev/null \
    ; open "$HOME/Library/Developer/Xcode/DerivedData/VoiceBubble-arbvxvbxxsnfymbulsnszkqkgdon/Build/Products/Debug/VoiceBubble.app"
  ```
- **No unit tests in this plan**: the project has no test suite for UI; verification is build-success + visual checkpoint after restart. Each task lists the explicit thing to look at on screen.
- **Commit per task** with the message shown.
- **Working directory in shell commands**: always quote because of the space — `cd "~/IDE project/Voice Bubble"`.

---

## Task 1: Scaffold the new shared components (Spacing + mono)

**Files:**
- Create: `VoiceBubble/Frontend/Components/Spacing.swift`
- Create: `VoiceBubble/Frontend/Components/MonoTextExtension.swift`
- Modify: `VoiceBubble.xcodeproj/project.pbxproj` (add the two files to the build target — Xcode does this automatically on next open, but since we don't open Xcode, we add via xcodeproj edit OR rely on `xcodebuild` discovering them through the file system source-membership rules)

> **Note on project.pbxproj**: Voice Bubble appears to use file-system-based source discovery (every `.swift` under `VoiceBubble/` is compiled). Verify by checking that recent additions like `FocusObserver.swift` (currently untracked but presumably built) work without manual pbxproj edits. If yes, skip the pbxproj edits in tasks 1, 2, 3.

- [ ] **Step 1.1: Create Spacing.swift**

```swift
// VoiceBubble/Frontend/Components/Spacing.swift
import CoreGraphics

/// Codex follows a strict 4-pt grid. Use these constants instead of magic numbers.
enum Spacing {
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 12
    static let lg:  CGFloat = 16
    static let xl:  CGFloat = 24
    static let xxl: CGFloat = 32
}
```

- [ ] **Step 1.2: Create MonoTextExtension.swift**

```swift
// VoiceBubble/Frontend/Components/MonoTextExtension.swift
import SwiftUI

extension Text {
    /// Codex mono text — for "machine output": timers, model IDs, file paths,
    /// keybind labels, error codes. NOT for prose. See spec §4.4.
    func mono(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> some View {
        self.font(.system(size: size, weight: weight, design: .monospaced))
    }
}

extension View {
    /// Apply mono digit style to numeric labels (timers, sliders).
    func monoDigits(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> some View {
        self.font(.system(size: size, weight: weight, design: .monospaced).monospacedDigit())
    }
}
```

- [ ] **Step 1.3: Build to verify both files compile and pbxproj auto-discovers them**

```bash
cd "~/IDE project/Voice Bubble"
xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet
```

Expected: `** BUILD SUCCEEDED **`. If pbxproj does NOT auto-discover, error like `cannot find 'Spacing' in scope` appears in later tasks — add the files manually via `xed` or open the project once.

- [ ] **Step 1.4: Commit**

```bash
git add VoiceBubble/Frontend/Components/Spacing.swift \
        VoiceBubble/Frontend/Components/MonoTextExtension.swift
git commit -m "feat(ui): add Spacing constants and Text.mono() helper

Codex 4-pt grid + mono helpers for machine-output labels.
Used by upcoming Codex-style redesign (spec §4.4, §5.4).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Add Codex button styles

**Files:**
- Create: `VoiceBubble/Frontend/Components/CodexButtonStyles.swift`

- [ ] **Step 2.1: Write the new ButtonStyles**

```swift
// VoiceBubble/Frontend/Components/CodexButtonStyles.swift
import SwiftUI

/// Solid green primary CTA — "Stage all" / "Send" / 启动服务. Spec §6.4.
struct CodexPrimaryButtonStyle: ButtonStyle {
    @EnvironmentObject private var theme: ThemeManager
    var minHeight: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .frame(minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(buttonFill(configuration: configuration))
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func buttonFill(configuration: Configuration) -> Color {
        configuration.isPressed
            ? theme.accent.opacity(0.85)
            : theme.accent
    }
}

/// Transparent + hairline border. For 取消 / 设置 / 次要操作. Spec §6.4.
struct CodexSecondaryButtonStyle: ButtonStyle {
    @EnvironmentObject private var theme: ThemeManager
    var minHeight: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundColor(theme.textPrimary)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .frame(minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? theme.tagBackground : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Red-outline button for destructive actions (停止录制 / 删除). Spec §6.4.
struct CodexDestructiveButtonStyle: ButtonStyle {
    @EnvironmentObject private var theme: ThemeManager
    var minHeight: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(theme.destructive)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .frame(minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed
                          ? theme.destructive.opacity(0.18)
                          : theme.destructive.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(theme.destructive.opacity(0.5), lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
```

- [ ] **Step 2.2: Build (no app behavior change yet — file only adds new types)**

```bash
cd "~/IDE project/Voice Bubble"
xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2.3: Commit**

```bash
git add VoiceBubble/Frontend/Components/CodexButtonStyles.swift
git commit -m "feat(ui): add Codex primary/secondary/destructive button styles

Solid green primary, transparent+hairline secondary, red-outline destructive.
Spec §6.4.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Add CodexBadge component

**Files:**
- Create: `VoiceBubble/Frontend/Components/CodexBadge.swift`

- [ ] **Step 3.1: Write CodexBadge**

```swift
// VoiceBubble/Frontend/Components/CodexBadge.swift
import SwiftUI

/// Small rectangular badge — used for hotword tags, status pills, provenance
/// chips. Codex shape language: small radius rectangles, mono label, neutral
/// fill, optional leading SF Symbol. Spec §6.7.
struct CodexBadge: View {
    enum Variant {
        case neutral       // hotword / generic tag
        case running       // amber
        case success       // green (ready/online)
        case error         // red
        case cloud         // neutral grey + cloud icon
        case local         // neutral grey + lock.shield icon
    }

    let text: String
    var variant: Variant = .neutral
    var icon: String? = nil
    var onClose: (() -> Void)? = nil

    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        HStack(spacing: 4) {
            if let icon = effectiveIcon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(fg)
            }
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(fg)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(fg.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(bg)
        )
    }

    private var effectiveIcon: String? {
        if let icon { return icon }
        switch variant {
        case .cloud: return "cloud.fill"
        case .local: return "lock.shield.fill"
        default: return nil
        }
    }

    private var fg: Color {
        switch variant {
        case .neutral, .cloud, .local: return theme.textSecondary
        case .running: return theme.warning
        case .success: return theme.accent
        case .error:   return theme.destructive
        }
    }

    private var bg: Color {
        switch variant {
        case .neutral, .cloud, .local: return theme.tagBackground
        case .running: return theme.warning.opacity(0.15)
        case .success: return theme.accent.opacity(0.15)
        case .error:   return theme.destructive.opacity(0.15)
        }
    }
}
```

- [ ] **Step 3.2: Build**

```bash
cd "~/IDE project/Voice Bubble"
xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3.3: Commit**

```bash
git add VoiceBubble/Frontend/Components/CodexBadge.swift
git commit -m "feat(ui): add CodexBadge component (neutral/running/success/error/cloud/local)

Small rectangular pills with mono label and optional SF Symbol icon.
Replaces ad-hoc Capsule()-with-color tags in favour of a single style. Spec §6.7.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Rewrite ThemeManager — collapse to single Codex theme

This is the largest single change. We replace the entire 920-line file.

**Files:**
- Modify: `VoiceBubble/Shared/ThemeManager.swift` (full rewrite)

- [ ] **Step 4.1: Write the new ThemeManager**

```swift
// VoiceBubble/Shared/ThemeManager.swift
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

extension AppTheme {
    var pickerSwatch: Color { Color(hex: "202123") }
    var previewColors: [Color] { [Color(hex: "202123"), Color(hex: "10A37F")] }
}
```

> **Why this list of properties is exhaustive**: every property name in this file is referenced by the existing tabs/components. Removing one breaks the build. Property bodies become trivial; we keep the property surface stable.

> **What was removed**: `bubbleColors`, `bubbleCoreOpacity`, `bubbleGlowOpacity`, `bubbleHighlightOpacity`, `bubbleRingOpacity`, `bgGradientColors`, `Decoration` enum + `decoration` property — these were only consumed by `GlassmorphismBackground` (deleted in Task 6) and the sidebar's `if theme.decoration == .expressive` branch (collapsed in Task 7).

- [ ] **Step 4.2: Build — expect failures in 4 places**

```bash
cd "~/IDE project/Voice Bubble"
xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet 2>&1 | grep -E "(error:|warning:)" | head -40
```

Expected errors (these are the consumers of the now-removed properties; they will be fixed in Tasks 5–7 and 14):
- `GlassmorphismBackground.swift:79: error: value of type 'ThemeManager' has no member 'bubbleColors'`
- `GlassmorphismBackground.swift:208: error: value of type 'ThemeManager' has no member 'bgGradientColors'`
- `MainWindow.swift:101: error: value of type 'ThemeManager' has no member 'decoration'`
- Possibly references in `AboutTab.swift` to `AppTheme.allCases` if a picker exists

**Do not commit yet** — proceed to Task 5 to fix `GlassmorphismBackground` consumers (delete the file in Task 6) before commit.

> Build is intentionally broken at this checkpoint. The next 3 tasks restore green build incrementally. If you want a green tip per commit, you can fold tasks 4-7 into a single commit at the end of Task 7 — but the recommended flow is to keep them separate and only build-verify after Task 7.

---

## Task 5: Simplify GlassCardModifier

**Files:**
- Modify: `VoiceBubble/Frontend/Components/ColorExtension.swift` (lines 33-107 — the `glassCard` modifier and its `GlassCardModifier` struct)

- [ ] **Step 5.1: Replace the modifier code (lines 33-107)**

Open `VoiceBubble/Frontend/Components/ColorExtension.swift` and replace everything from line 33 (`// MARK: - Card Modifier`) to end of file with:

```swift
// MARK: - Card Modifier

extension View {
    /// Codex card surface — flat fill, hairline border, sharp corners, no shadow.
    /// `cornerRadius` overrides the theme default; `borderColor` overrides the
    /// theme border. Spec §6.3.
    func glassCard(cornerRadius: CGFloat? = nil, borderColor: Color? = nil) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, borderColor: borderColor))
    }
}

private struct GlassCardModifier: ViewModifier {
    @EnvironmentObject private var theme: ThemeManager
    let cornerRadius: CGFloat?
    let borderColor: Color?

    func body(content: Content) -> some View {
        let r = cornerRadius ?? theme.cardBaseCornerRadius

        return content
            .background(
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .fill(theme.cardOverlayColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .stroke(borderColor ?? theme.cardBorderColor,
                            lineWidth: theme.cardBorderWidth)
            )
    }
}
```

- [ ] **Step 5.2: Build**

```bash
cd "~/IDE project/Voice Bubble"
xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet 2>&1 | grep -E "error:" | head -20
```

Expected: still has the 3 GlassmorphismBackground / MainWindow errors from Task 4.2 (those get fixed in next task). No NEW errors from this file.

- [ ] **Step 5.3: Stage but don't commit yet — folded into Task 7 commit**

```bash
git add VoiceBubble/Frontend/Components/ColorExtension.swift
```

---

## Task 6: Delete GlassmorphismBackground and switch MainWindow background

**Files:**
- Delete: `VoiceBubble/Frontend/Components/GlassmorphismBackground.swift`
- Modify: `VoiceBubble/Frontend/MainWindow.swift:118` (background line)

- [ ] **Step 6.1: Delete GlassmorphismBackground.swift**

```bash
cd "~/IDE project/Voice Bubble"
git rm VoiceBubble/Frontend/Components/GlassmorphismBackground.swift
```

- [ ] **Step 6.2: Edit MainWindow.swift line 118**

Find:
```swift
        .background(GlassmorphismBackground().ignoresSafeArea())
```

Replace with:
```swift
        .background(theme.windowBackground.ignoresSafeArea())
```

- [ ] **Step 6.3: Build**

```bash
cd "~/IDE project/Voice Bubble"
xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet 2>&1 | grep -E "error:" | head -20
```

Expected: only remaining error should be about `theme.decoration` in MainWindow.swift line 101 area. Fixed in Task 7.

---

## Task 7: Restyle MainWindow shell + sidebar

**Files:**
- Modify: `VoiceBubble/Frontend/MainWindow.swift` (sidebar background block + nav item visuals)

- [ ] **Step 7.1: Replace the sidebar background block (lines 89-114)**

Find this block (currently lines 89-114):

```swift
                sidebar
                    .frame(width: 76, height: geometry.size.height)
                    .background(
                        // Minimal & material themes both have visibly tinted
                        // ...long comment block...
                        Group {
                            if theme.decoration == .expressive {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(.ultraThinMaterial)
                            } else {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(theme.sidebarBackground)
                            }
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(theme.border.opacity(0.4), lineWidth: 0.5)
                    )
```

Replace with:

```swift
                sidebar
                    .frame(width: 76, height: geometry.size.height)
                    .background(theme.sidebarBackground)
                    .overlay(alignment: .trailing) {
                        // Codex sidebar: flat full-height panel + 1pt vertical
                        // hairline divider on the inside edge. No rounded corners,
                        // no shadow — sidebar is structure, not a floating card.
                        Rectangle()
                            .fill(theme.border)
                            .frame(width: 1)
                    }
```

- [ ] **Step 7.2: Replace the navItem function (lines 255-278)**

Find:
```swift
    private func navItem(for tab: AppTab) -> some View {
        let isSelected = selectedTab == tab

        return Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.78, blendDuration: 0.05)) {
                selectedTab = tab
            }
        } label: {
            Image(systemName: tab.icon)
                .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                .frame(width: 40, height: 40)
                .foregroundColor(isSelected ? theme.accentSecondary : theme.sidebarText)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? theme.sidebarSelectedBg : Color.clear)
                )
                .scaleEffect(isSelected ? 1.0 : 0.96)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(tab.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(tab.accessibilityLabel)
    }
```

Replace with:

```swift
    private func navItem(for tab: AppTab) -> some View {
        let isSelected = selectedTab == tab

        return Button {
            // Codex motion language: ease-out, no spring bounce.
            withAnimation(.easeOut(duration: 0.15)) {
                selectedTab = tab
            }
        } label: {
            Image(systemName: tab.icon)
                .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                .frame(width: 40, height: 40)
                .foregroundColor(isSelected ? theme.accent : theme.sidebarText)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? theme.sidebarSelectedBg : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(tab.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(tab.accessibilityLabel)
    }
```

- [ ] **Step 7.3: Build**

```bash
cd "~/IDE project/Voice Bubble"
xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet
```

Expected: `** BUILD SUCCEEDED **` (or close to it; if any other file references removed `theme.bubbleColors` etc, fix those too — should be only AboutTab area which is handled in Task 14).

If errors remain, list them and address before proceeding.

- [ ] **Step 7.4: Restart and visual checkpoint**

```bash
pkill -x "VoiceBubble" 2>/dev/null
open "$HOME/Library/Developer/Xcode/DerivedData/VoiceBubble-arbvxvbxxsnfymbulsnszkqkgdon/Build/Products/Debug/VoiceBubble.app"
```

Visual checks (look at screen):
- [ ] Main window background is uniform near-black (`#0E0F12`), no animated bubbles, no gradients
- [ ] Sidebar is darker grey (`#202123`) full-height with 1pt hairline on the right edge
- [ ] No rounded corners on sidebar — it abuts the window edges
- [ ] Selected tab icon shows in green (`#10A37F`) on tinted green background
- [ ] Tab content area is also `#0E0F12` (matches window — no separate panel surface)

Issues are likely cosmetic (cards may still have old fill etc.) — those are expected at this stage.

- [ ] **Step 7.5: Commit Tasks 4-7 together**

```bash
cd "~/IDE project/Voice Bubble"
git add VoiceBubble/Shared/ThemeManager.swift \
        VoiceBubble/Frontend/Components/ColorExtension.swift \
        VoiceBubble/Frontend/MainWindow.swift
git commit -m "refactor(ui): collapse ThemeManager to single Codex theme + flat shell

- AppTheme reduced to one case (.codex); old themes (sakura/mint/etc.)
  silently migrate to .codex on launch.
- All design tokens swapped to Codex brand palette (#0E0F12 / #202123 /
  #10A37F / #40434A); see spec §5.1 for the full table.
- glassCard() simplified to one rendering branch (flat fill + hairline,
  no material/shadow/decoration switch).
- GlassmorphismBackground deleted — Codex has no animated background.
- Sidebar restyled to flat full-height with vertical hairline divider;
  selected nav state uses accent green; spring animation removed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Update CustomToggleStyle for Codex motion

**Files:**
- Modify: `VoiceBubble/Frontend/Components/CustomToggleStyle.swift` (entire body)

- [ ] **Step 8.1: Replace the file content**

```swift
// VoiceBubble/Frontend/Components/CustomToggleStyle.swift
import SwiftUI

/// Codex toggle: green track when on, hairline-grey when off, white knob,
/// ease-out motion (no spring bounce). Spec §6.5.
struct CustomToggleStyle: ToggleStyle {
    @EnvironmentObject private var theme: ThemeManager

    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn

        return ZStack(alignment: isOn ? .trailing : .leading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isOn ? theme.accent : theme.toggleInactive)
                .frame(width: 44, height: 24)

            Circle()
                .fill(.white)
                .frame(width: 18, height: 18)
                .padding(3)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
                configuration.isOn.toggle()
            }
        }
        .accessibilityValue(isOn ? "已开启" : "已关闭")
        .accessibilityAddTraits(.isButton)
    }
}
```

- [ ] **Step 8.2: Build + restart**

```bash
cd "~/IDE project/Voice Bubble"
xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet \
  && pkill -x "VoiceBubble" 2>/dev/null \
  ; open "$HOME/Library/Developer/Xcode/DerivedData/VoiceBubble-arbvxvbxxsnfymbulsnszkqkgdon/Build/Products/Debug/VoiceBubble.app"
```

Visual checks:
- [ ] Open Voice tab; toggle "语气词过滤" on and off — track switches between green and dark grey, knob slides without spring bounce, no scale-down

- [ ] **Step 8.3: Commit**

```bash
git add VoiceBubble/Frontend/Components/CustomToggleStyle.swift
git commit -m "refactor(ui): Codex-style toggle (green track, ease-out, no spring)

Removes pressed-scale and stretch-knob effects in favour of Codex's
restrained motion language. Spec §6.5.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Restyle RecordingOverlayPanel

**Files:**
- Modify: `VoiceBubble/Frontend/Components/RecordingOverlayPanel.swift`
- Modify: `VoiceBubble/Frontend/Components/RecordingWaveformView.swift` (waveform color is already from theme — no change expected, but verify)

- [ ] **Step 9.1: Update RecordingOverlayContentView to add REC label + use mono**

In `RecordingOverlayPanel.swift`, find `struct RecordingOverlayContentView: View` (around line 56) and replace its body with:

```swift
struct RecordingOverlayContentView: View {
    @ObservedObject var streamingState: StreamingTextState
    @EnvironmentObject private var theme: ThemeManager

    @State private var dotOpacity: Double = 1.0

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // REC indicator: red dot + mono REC label. Meeting mode also shows
            // an inline timer. Spec §6.8.
            HStack(spacing: 4) {
                Circle()
                    .fill(theme.destructive)
                    .frame(width: 6, height: 6)
                    .opacity(dotOpacity)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                            dotOpacity = 0.35
                        }
                    }
                Text("REC")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.destructive)

                if streamingState.mode == .meeting && streamingState.meetingElapsed > 0 {
                    Text(formatElapsed(streamingState.meetingElapsed))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.textSecondary)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)

            RecordingWaveformView(streamingState: streamingState)
                .frame(width: 36, height: 36)

            if streamingState.isEnabled && !streamingState.text.isEmpty {
                Text(streamingState.text)
                    .font(.system(size: streamingState.fontSize, weight: .medium))
                    .foregroundColor(theme.textPrimary)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: streamingState.maxTextWidth, alignment: .leading)
                    .padding(.vertical, 12)
                    .padding(.trailing, 16)
                    .padding(.leading, 4)
            }
        }
        .frame(minHeight: 36, alignment: .center)
        .background(theme.surfaceBackground)
    }

    private func formatElapsed(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}
```

- [ ] **Step 9.2: Update the panel constants and replace NSVisualEffectView with a plain layer-backed NSView**

In `RecordingOverlayPanel.swift`, find:

```swift
    private let compactSize: CGFloat = 44
    private let topPadding: CGFloat = 20
    private let cornerRadius: CGFloat = 22
    /// Waveform area + trailing padding
    private let horizontalOverhead: CGFloat = 60
```

Replace with:

```swift
    private let compactSize: CGFloat = 44
    private let topPadding: CGFloat = 20
    /// Codex HUD radius — slightly larger than card radius (8) to read as a
    /// pill, but not full circle. Spec §6.8.
    private let cornerRadius: CGFloat = 12
    /// REC label + waveform + trailing padding
    private let horizontalOverhead: CGFloat = 110
```

Then find the `init()` block and replace the NSVisualEffectView section (around lines 173-198) with:

```swift
        // Codex HUD: flat dark surface, hairline border, drop shadow for
        // floating presence on bright wallpapers. No vibrancy/material.
        let backdrop = NSView()
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(red: 0x20/255.0, green: 0x21/255.0, blue: 0x23/255.0, alpha: 1.0).cgColor
        backdrop.layer?.cornerRadius = cornerRadius
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.borderColor = NSColor(red: 0x40/255.0, green: 0x43/255.0, blue: 0x4A/255.0, alpha: 1.0).cgColor
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.masksToBounds = true
        backdrop.frame = NSRect(x: 0, y: 0, width: compactSize, height: compactSize)
        backdrop.autoresizingMask = [.width, .height]

        // Shape mask for crisp clipping on resize
        let shapeMask = CAShapeLayer()
        shapeMask.path = CGPath(roundedRect: backdrop.bounds,
                                 cornerWidth: cornerRadius,
                                 cornerHeight: cornerRadius,
                                 transform: nil)
        backdrop.layer?.mask = shapeMask

        hosting.layer?.cornerRadius = cornerRadius
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true

        backdrop.addSubview(hosting)
        self.contentView = backdrop

        // Window-level shadow (Codex-style "floating" weight)
        hasShadow = true
```

Also find the `hasShadow = false` line near the top of init and change it to `hasShadow = true` (or delete it since the new code sets it). Make sure only one `hasShadow = ...` survives.

- [ ] **Step 9.3: Update `configure()` to also use the new backdrop**

Find the `func configure(themeManager:)` block (around line 120) and replace with:

```swift
    func configure(themeManager: ThemeManager) {
        let rootView = AnyView(
            RecordingOverlayContentView(streamingState: streamingState)
                .environmentObject(themeManager)
        )
        let hosting = NSHostingView(rootView: rootView)
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(x: 0, y: 0, width: compactSize, height: compactSize)
        hosting.layer?.cornerRadius = cornerRadius
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        self.hostingView = hosting

        if let backdrop = contentView {
            backdrop.subviews.forEach { $0.removeFromSuperview() }
            backdrop.addSubview(hosting)
        }
    }
```

- [ ] **Step 9.4: Update `resizePanelToFitContent()` to update the layer-backed view (not NSVisualEffectView)**

Find the `private func resizePanelToFitContent()` block (around line 340), and inside it find the `if let visualEffect = contentView as? NSVisualEffectView { ... }` block. Replace that block with:

```swift
        // Update corner radius and mask for new size
        let radius = min(panelHeight / 2, cornerRadius)
        if let backdrop = contentView {
            backdrop.layer?.cornerRadius = radius
            if let shapeMask = backdrop.layer?.mask as? CAShapeLayer {
                shapeMask.path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
                                         cornerWidth: radius,
                                         cornerHeight: radius,
                                         transform: nil)
            }
        }
        hostingView?.layer?.cornerRadius = radius
```

- [ ] **Step 9.5: Build + restart**

```bash
cd "~/IDE project/Voice Bubble"
xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet \
  && pkill -x "VoiceBubble" 2>/dev/null \
  ; open "$HOME/Library/Developer/Xcode/DerivedData/VoiceBubble-arbvxvbxxsnfymbulsnszkqkgdon/Build/Products/Debug/VoiceBubble.app"
```

Visual checks:
- [ ] Hold the trigger key — overlay appears at screen top center
- [ ] Background is solid dark `#202123`, not vibrancy/blur
- [ ] Red dot + "REC" mono label visible on the left
- [ ] Waveform bars are green `#10A37F`
- [ ] Drop shadow gives the panel some weight against bright wallpapers
- [ ] Release the trigger — fade out works

If positioning of the new wider 110px overhead breaks the centering, adjust `horizontalOverhead` value or check that `setContentSize` / `positionAtScreenTopCenter` still produce centered placement.

- [ ] **Step 9.6: Commit**

```bash
git add VoiceBubble/Frontend/Components/RecordingOverlayPanel.swift
git commit -m "refactor(overlay): Codex HUD — flat dark surface, mono REC, green waveform

- Replace NSVisualEffectView with layer-backed NSView (#202123 fill,
  #40434A border, system shadow). Vibrancy removed.
- Add red blinking dot + mono \"REC\" label on the left; meeting mode
  appends mono timer.
- Waveform color comes from theme.accent (#10A37F).
- Corner radius bumped to 12 (HUD-class).
- floating-level / click-through / non-activating panel preserved
  (PROJECT.md 4.4 hard constraint).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Migrate VoiceTab + VoiceSettingsSection (largest tab)

**Files:**
- Modify: `VoiceBubble/Frontend/Tabs/Sections/VoiceSettingsSection.swift` (1173 lines — surgical changes only)

> Theming is already abstracted via `theme.*` calls, so most colors flip automatically. This task only does targeted swaps.

- [ ] **Step 10.1: Find every Button using inline `.padding(...).background(Capsule().fill(...))` and migrate to CodexButtonStyles**

Run this to enumerate them:
```bash
cd "~/IDE project/Voice Bubble"
grep -n "Capsule().fill" VoiceBubble/Frontend/Tabs/Sections/VoiceSettingsSection.swift
grep -n ".background(.*RoundedRectangle.*\\.fill(theme.accent" VoiceBubble/Frontend/Tabs/Sections/VoiceSettingsSection.swift
```

For each match, decide:
- If it's a primary CTA (启动/确认/保存) → replace inline styling with `.buttonStyle(CodexPrimaryButtonStyle())`
- If it's a secondary action (取消/编辑) → `.buttonStyle(CodexSecondaryButtonStyle())`
- If it's destructive (删除/停止) → `.buttonStyle(CodexDestructiveButtonStyle())`

Example transformation: find a button like
```swift
Button { ... } label: {
    Text("保存")
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Capsule().fill(theme.accent))
}
.buttonStyle(.plain)
```

Replace with:
```swift
Button("保存") { ... }
    .buttonStyle(CodexPrimaryButtonStyle())
```

- [ ] **Step 10.2: Replace hotword Capsule tags with CodexBadge**

Find the hotword display (search for `theme.tagBackground` near hotword logic). Replace each instance pattern of:
```swift
HStack(spacing: 4) {
    Text(hotword)
    Button { /* delete */ } label: { Image(systemName: "xmark") }
}
.padding(...)
.background(Capsule().fill(theme.tagBackground))
```

With:
```swift
CodexBadge(text: hotword, onClose: { /* delete logic */ })
```

- [ ] **Step 10.3: Add mono to specific labels**

For each of the following text fields, add mono styling:

1. Trigger key display (look for `triggerKeyCard` block, the dropdown selection text)
2. Model ID labels (look for `Qwen3-ASR` or similar)
3. Replacement rule from/to columns

Example: a label currently rendered as
```swift
Text(model.displayName)
    .font(.system(size: 13))
```

If this text is a model ID like "Qwen3-ASR-1.7B" (not 中文 description), change to:
```swift
Text(model.displayName)
    .mono(13)
```

Use judgment: if it's a Chinese description, keep sans. If it's an English/Latin technical identifier, use mono.

- [ ] **Step 10.4: Replace provenanceBadge() inline implementation with CodexBadge**

Find the `private func provenanceBadge(isCloud: Bool) -> some View` (around line 146). Replace its body:

```swift
    private func provenanceBadge(isCloud: Bool) -> some View {
        CodexBadge(text: isCloud ? "云端" : "本地",
                   variant: isCloud ? .cloud : .local)
    }
```

- [ ] **Step 10.5: Build + restart**

```bash
cd "~/IDE project/Voice Bubble"
xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet \
  && pkill -x "VoiceBubble" 2>/dev/null \
  ; open "$HOME/Library/Developer/Xcode/DerivedData/VoiceBubble-arbvxvbxxsnfymbulsnszkqkgdon/Build/Products/Debug/VoiceBubble.app"
```

Visual checks (Voice tab):
- [ ] Cards have hairline borders, sharp corners, dark fill
- [ ] All buttons use Codex shape (rectangle 6px corner, not capsule)
- [ ] Hotword tags are small rectangles with mono label
- [ ] Model IDs render in mono
- [ ] Cloud/local badges show as mono pills with icon
- [ ] Toggle switches green when on
- [ ] All text legible against dark background

- [ ] **Step 10.6: Commit**

```bash
git add VoiceBubble/Frontend/Tabs/Sections/VoiceSettingsSection.swift
git commit -m "refactor(voice-tab): migrate buttons/badges/IDs to Codex style

- Inline button styling replaced by CodexPrimary/Secondary/Destructive
- Hotword tags now use CodexBadge
- Model IDs and trigger key labels rendered in monospace
- Provenance badges use CodexBadge cloud/local variants

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: Migrate MeetingTab + MeetingSettingsSection

**Files:**
- Modify: `VoiceBubble/Frontend/Tabs/MeetingTab.swift`
- Modify: `VoiceBubble/Frontend/Tabs/Sections/MeetingSettingsSection.swift`

- [ ] **Step 11.1: Migrate MeetingTab.swift**

Apply the same patterns as Task 10:
- Replace inline button styling with `CodexPrimary/Secondary/DestructiveButtonStyle`
- Specifically the **start/stop meeting** buttons:
  - Start = `CodexPrimaryButtonStyle()` (green)
  - Stop = `CodexDestructiveButtonStyle()` (red outline)
- Make the **elapsed timer** display use mono: change its `.font(...)` call to `.font(.system(size: 18, weight: .semibold, design: .monospaced).monospacedDigit())`

- [ ] **Step 11.2: Migrate MeetingSettingsSection.swift**

- File path display (the meeting save path) should be mono — find any `Text(savePath)` rendering and add `.mono(12)`.
- Buttons → CodexButtonStyles.
- Toggle rows already use the new CustomToggleStyle automatically (no changes needed).

- [ ] **Step 11.3: Build + restart + visual check**

```bash
cd "~/IDE project/Voice Bubble"
xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet \
  && pkill -x "VoiceBubble" 2>/dev/null \
  ; open "$HOME/Library/Developer/Xcode/DerivedData/VoiceBubble-arbvxvbxxsnfymbulsnszkqkgdon/Build/Products/Debug/VoiceBubble.app"
```

- [ ] Visual: Meeting tab — start meeting button is green, stop is red outline, file path appears in mono
- [ ] Click "开始会议" — overlay shows REC + green waveform + mono timer ticking

- [ ] **Step 11.4: Commit**

```bash
git add VoiceBubble/Frontend/Tabs/MeetingTab.swift \
        VoiceBubble/Frontend/Tabs/Sections/MeetingSettingsSection.swift
git commit -m "refactor(meeting-tab): Codex buttons + mono path/timer

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Migrate HistoryTab

**Files:**
- Modify: `VoiceBubble/Frontend/Tabs/HistoryTab.swift` (776 lines)

- [ ] **Step 12.1: Make timestamps and durations mono**

In the voice/meeting history list rows, find any time display like `2026-05-15 14:30:42` or `00:42` durations. Add `.mono(11)` to those Text views.

- [ ] **Step 12.2: Make file size labels mono (e.g. "1.2 MB")**

Same treatment.

- [ ] **Step 12.3: Replace any Capsule-styled date-group headers with simple section headers + hairline divider**

If the date groups (今天/昨天/本周/更早) are styled as colored capsules, simplify to:
```swift
HStack {
    Text(group.title)
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(theme.textTertiary)
        .textCase(.uppercase)
    Rectangle()
        .fill(theme.borderLight)
        .frame(height: 1)
}
```

- [ ] **Step 12.4: Migrate buttons** (export, clear, copy) — use `CodexSecondaryButtonStyle()` for export/copy, `CodexDestructiveButtonStyle()` for clear.

- [ ] **Step 12.5: Build + restart + visual check**

```bash
cd "~/IDE project/Voice Bubble"
xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet \
  && pkill -x "VoiceBubble" 2>/dev/null \
  ; open "$HOME/Library/Developer/Xcode/DerivedData/VoiceBubble-arbvxvbxxsnfymbulsnszkqkgdon/Build/Products/Debug/VoiceBubble.app"
```

- [ ] Visual: History tab shows records with mono timestamps, hairline section dividers, Codex buttons

- [ ] **Step 12.6: Commit**

```bash
git add VoiceBubble/Frontend/Tabs/HistoryTab.swift
git commit -m "refactor(history-tab): mono timestamps + hairline dividers + Codex buttons

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: Migrate GeneralTab + GeneralSettingsSection + AboutTab + delete theme picker

**Files:**
- Modify: `VoiceBubble/Frontend/Tabs/Sections/GeneralSettingsSection.swift`
- Modify: `VoiceBubble/Frontend/Tabs/AboutTab.swift`

- [ ] **Step 13.1: Find and remove the theme picker UI block in AboutTab**

```bash
cd "~/IDE project/Voice Bubble"
grep -n "AppTheme\\.selectableCases\\|pickerSwatch\\|外观" VoiceBubble/Frontend/Tabs/AboutTab.swift
```

Locate the appearance-section and delete the entire block (the section header "外观" + the 5-swatch picker + any cardDepth segmented control).

After deletion, also remove unused `@EnvironmentObject` references if they were only used for that section.

Add a small attribution line at the bottom of the page:

```swift
Text("UI 风格：OpenAI Codex Mac App")
    .font(.system(size: 11))
    .foregroundColor(theme.textTertiary)
```

- [ ] **Step 13.2: Migrate AboutTab buttons + version label**

Version number / build number → `.mono(12)`.
"打开权限设置" buttons → `CodexSecondaryButtonStyle()`.

- [ ] **Step 13.3: Migrate GeneralSettingsSection**

Apply the same migration pattern (Capsule buttons → CodexButtonStyles, IDs → mono).

- [ ] **Step 13.4: Build + restart + visual check**

```bash
cd "~/IDE project/Voice Bubble"
xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet \
  && pkill -x "VoiceBubble" 2>/dev/null \
  ; open "$HOME/Library/Developer/Xcode/DerivedData/VoiceBubble-arbvxvbxxsnfymbulsnszkqkgdon/Build/Products/Debug/VoiceBubble.app"
```

- [ ] Visual: General tab + About tab — no theme swatches anywhere, version number is mono, "UI 风格：OpenAI Codex Mac App" small text at the bottom of About

- [ ] **Step 13.5: Commit**

```bash
git add VoiceBubble/Frontend/Tabs/AboutTab.swift \
        VoiceBubble/Frontend/Tabs/Sections/GeneralSettingsSection.swift
git commit -m "refactor(about/general): remove theme picker, mono version, Codex buttons

Theme picker removed because the app now ships with a single Codex theme.
About page footer notes the UI provenance.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 14: Migrate OnboardingView

**Files:**
- Modify: `VoiceBubble/Frontend/OnboardingView.swift`

- [ ] **Step 14.1: Replace any inline button styling**

Same pattern as Task 10. Three permission buttons probably exist; each "去授权" → `CodexSecondaryButtonStyle()`. The final "开始使用" → `CodexPrimaryButtonStyle()`. "稍后再说" → `CodexSecondaryButtonStyle()`.

- [ ] **Step 14.2: Verify the modal background uses theme tokens**

Search for any hardcoded `Color.white` or `Color(hex: ...)` in OnboardingView. Replace with `theme.surfaceBackground` etc.

- [ ] **Step 14.3: Build + restart + visual check**

```bash
cd "~/IDE project/Voice Bubble"
xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet \
  && pkill -x "VoiceBubble" 2>/dev/null \
  ; open "$HOME/Library/Developer/Xcode/DerivedData/VoiceBubble-arbvxvbxxsnfymbulsnszkqkgdon/Build/Products/Debug/VoiceBubble.app"
```

To trigger onboarding for visual verification, temporarily reset the flag:
```bash
defaults delete com.zhangzheng.VoiceBubble onboardingDone 2>/dev/null
```
Then restart the app. After visual check, the user can click "稍后再说" to dismiss without affecting the real preference.

- [ ] Visual: Onboarding sheet shows on dark surface, buttons use Codex styles, no light/glass artifacts

- [ ] **Step 14.4: Commit**

```bash
git add VoiceBubble/Frontend/OnboardingView.swift
git commit -m "refactor(onboarding): Codex-style buttons + dark surface

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 15: Update MenuBarController (popup menu visuals + status text)

**Files:**
- Modify: `VoiceBubble/Frontend/MenuBarController.swift`

> NSMenu items inherit macOS system styling — we can't deeply restyle a system NSMenu. The only Codex-style improvements to make are: (a) ensure status text uses mono where appropriate, (b) keep the icon as template image so it adapts to system menubar dark/light.

- [ ] **Step 15.1: Verify icon is template-mode in all states**

Find `image?.isTemplate = (tint == nil)` (line 86). The current logic only marks template when there's no tint. For Codex consistency, the recording state uses `.systemRed` tint which is desired for that state — keep as is. No change needed unless visual check shows a problem.

- [ ] **Step 15.2: Make the menu's REC timer mono**

In `refreshAppearance()` find the line:
```swift
button.title = " REC \(formatElapsed(meetingService.elapsedSeconds))"
```

NSStatusItem button titles inherit the system menu bar font (proportional). True mono in the status bar is achievable via NSAttributedString. Replace with:

```swift
            let attrTitle = NSMutableAttributedString(string: " REC \(formatElapsed(meetingService.elapsedSeconds))")
            let monoFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            attrTitle.addAttribute(.font, value: monoFont, range: NSRange(location: 0, length: attrTitle.length))
            button.attributedTitle = attrTitle
            button.imagePosition = .imageLeading
            statusItem.length = NSStatusItem.variableLength
```

(Replace the entire `if case .recording = ...` block accordingly.)

- [ ] **Step 15.3: Build + restart + visual check**

```bash
cd "~/IDE project/Voice Bubble"
xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet \
  && pkill -x "VoiceBubble" 2>/dev/null \
  ; open "$HOME/Library/Developer/Xcode/DerivedData/VoiceBubble-arbvxvbxxsnfymbulsnszkqkgdon/Build/Products/Debug/VoiceBubble.app"
```

- [ ] Visual: Trigger a meeting recording — menu bar shows red `record.circle.fill` + " REC 00:01" with mono digits that don't jitter as seconds tick

- [ ] **Step 15.4: Commit**

```bash
git add VoiceBubble/Frontend/MenuBarController.swift
git commit -m "refactor(menubar): mono digits in REC timer

Uses NSAttributedString with monospacedDigitSystemFont so the seconds
counter doesn't visually jitter as digits change.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 16: Final pass — clean up unused code and end-to-end visual sweep

**Files:**
- Modify: `VoiceBubble/Shared/ThemeManager.swift` (final cleanup of any unreferenced legacy properties)

- [ ] **Step 16.1: Grep for any references to removed theme properties**

```bash
cd "~/IDE project/Voice Bubble"
grep -rn "theme.bubbleColors\\|theme.bubbleCoreOpacity\\|theme.bubbleGlowOpacity\\|theme.bubbleHighlightOpacity\\|theme.bubbleRingOpacity\\|theme.bgGradientColors\\|theme.decoration" VoiceBubble/
```

Expected: empty output. If any references remain, fix them (remove the surrounding code block).

- [ ] **Step 16.2: Grep for any leftover hardcoded hex colors that should be tokens**

```bash
grep -rn 'Color(hex: "' VoiceBubble/Frontend/ | grep -v ColorExtension.swift
```

Triage the results: any hex that matches the Codex palette is fine. Any hex from the old Glassmorphism era (e.g. `#7B8CF5`, `#FFB3C1`, `#A8E6CF`) should be swapped for `theme.accent` / `theme.destructive` / etc.

- [ ] **Step 16.3: Run a final clean build and restart**

```bash
cd "~/IDE project/Voice Bubble"
xcodebuild clean build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet \
  && pkill -x "VoiceBubble" 2>/dev/null \
  ; open "$HOME/Library/Developer/Xcode/DerivedData/VoiceBubble-arbvxvbxxsnfymbulsnszkqkgdon/Build/Products/Debug/VoiceBubble.app"
```

- [ ] **Step 16.4: Run the verification checklist from spec §10**

Walk through each item:
- [ ] Main window background `#0E0F12` solid
- [ ] Cards `#202123` + hairline `#40434A`
- [ ] Sidebar selected = green-tinted bg + green icon
- [ ] Trigger key label is mono "⌥ Right Option" (or equivalent)
- [ ] Model ID `Qwen3-ASR-1.7B` is mono
- [ ] Recording overlay: green waveform + mono "REC" + red blink dot
- [ ] Meeting overlay: mono timer
- [ ] Primary buttons green-filled-white
- [ ] Toggle on = green
- [ ] About has no theme picker
- [ ] Menu bar icon visible in light/dark system bar
- [ ] After downgrading from a hypothetical old `appTheme=sakura`, app launches without error and renders Codex
  - Test by running:
    ```bash
    defaults write com.zhangzheng.VoiceBubble appTheme -string "sakura"
    pkill -x "VoiceBubble"; open "$HOME/Library/Developer/Xcode/DerivedData/VoiceBubble-arbvxvbxxsnfymbulsnszkqkgdon/Build/Products/Debug/VoiceBubble.app"
    ```
    App should launch normally (the migration in `ThemeManager.init()` handles the unknown raw value by defaulting to `.codex`).
- [ ] All original recording / meeting / hotword / replacement / history flows still work

- [ ] **Step 16.5: Commit any cleanup changes**

```bash
git add -u
git commit -m "chore(ui): final Codex redesign cleanup pass

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

If no changes to commit (everything was already addressed in earlier tasks), skip this commit.

---

## Self-review (run after writing the plan, before executing)

**1. Spec coverage:**
- Spec §2 (philosophy) → reflected in token choices in Task 4 and motion changes in Tasks 7/8
- Spec §3 In/Out scope → matches Tasks 1-16
- Spec §4 (architecture) → Tasks 4 (ThemeManager), 5 (GlassCard), 6 (delete bg)
- Spec §5 (tokens) → Task 4
- Spec §6.1 (MainWindow) → Tasks 6, 7
- Spec §6.2 (sidebar) → Task 7
- Spec §6.3 (cards) → Task 5
- Spec §6.4 (buttons) → Task 2
- Spec §6.5 (toggle) → Task 8
- Spec §6.6 (input/picker) → relies on theme tokens, no separate task; if visual issues remain after Task 7 visual check, add a follow-up
- Spec §6.7 (badges) → Task 3
- Spec §6.8 (overlay) → Task 9
- Spec §6.9 (menu bar) → Task 15
- Spec §6.10 (about) → Task 13
- Spec §7.1 new files → Tasks 1, 2, 3
- Spec §7.2 rewrites → Tasks 4, 5, 7, 8, 9, 10-15
- Spec §7.3 deletes → Task 6
- Spec §7.4 deleted code segments → Task 13 (theme picker), distributed across other tasks for hardcoded colors
- Spec §8 ordering → matches plan task order
- Spec §9 risks → covered by visual checkpoints + Task 16.4 migration test
- Spec §10 verification → Task 16.4
- Spec §11 open questions → already resolved (proposal defaults adopted)

**2. Placeholder scan:** plan contains no "TBD" / "TODO" / "implement later". Each step has either exact code or a concrete grep / xcodebuild / pkill command.

**3. Type consistency:** `ThemeManager` properties used in Tasks 5+ all match what's defined in Task 4. `CodexBadge`, `CodexPrimary/Secondary/DestructiveButtonStyle`, `Spacing`, `Text.mono()` defined in Tasks 1-3 are referenced consistently downstream.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-15-codex-style-redesign.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, isolated failure surface.

**2. Inline Execution** — execute in current session with checkpoints.
