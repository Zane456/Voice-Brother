# 卡片对齐 + 品牌矢量图标 — 设计文档

日期：2026-05-16
分支：feat/meeting-ux-and-dialogue-rename

## 目标

让「语音输入」卡片与「对话记录」卡片**大小、风格一致**，并为两张卡片各配一个
与 App Logo 同主题的图标。图标随系统深浅色自动调节，无需额外图片资源。

## 背景

- 「对话记录」卡片（`MeetingTab.recordingControlCard`）已有 56pt 圆形徽章布局：
  `[徽章+图标] [标题+副标题] [Spacer] [按钮]`，徽章底色 `accent.opacity(0.12)`。
- 「语音输入」卡片（`VoiceSettingsSection.triggerKeyCard`）当前是一行
  `[标签] [Picker]` + 一行说明文字，没有徽章，视觉重量与前者不一致。
- `ThemeManager` 已监听 `effectiveAppearance`，`theme.accent`(#339CFF) /
  `theme.isDark` 在浅/深色下自动切换 → 跟随系统是现成能力。
- 现有 `Frontend/Components/StatusBarIcon.swift` 已用 `NSBezierPath` 画了
  「气泡 + 3 条声波竖条」的菜单栏图标，几何比例可作为新矢量图标的参照基准。

## 方案

### 1. 新文件：`Frontend/Components/BrandGlyphs.swift`

两个 SwiftUI `Shape`，**共用同一个气泡 `Path`**（椭圆气泡体 + 左下小尾巴，
比例参照 `StatusBarIcon.renderBubble`），只替换气泡内部元素，保证两图风格一致：

| Shape | 内部元素 | 用途 |
|-------|---------|------|
| `VoiceGlyph` | 3 条声波竖条（中间最高，圆角） | 「语音输入」卡片徽章（≈ Logo 本体） |
| `DialogueGlyph` | 3 条等距横线（圆角，代表转写出的文字） | 「对话记录」卡片徽章 |

实现要点：
- 单色绘制，由调用方通过 `.foregroundColor(theme.accent)` 上色 → 深浅色自动跟随。
- `Shape` 在传入的 `rect` 内按比例绘制，与尺寸无关 → 任意尺寸清晰。
- 气泡用描边（stroke），内部竖条/横线用填充（fill），与 Logo 视觉一致。
- 提供一个轻量包装视图 `BrandGlyphIcon`（可选），把 stroke 气泡 + fill 内容
  组合成一个可直接放进徽章的 `View`，避免在调用点重复组合逻辑。

### 2. 重排「语音输入」卡片 — `VoiceSettingsSection.triggerKeyCard`

改为与 `MeetingTab.recordingControlCard` 同款结构与尺寸：

```
HStack(spacing: 16) {
    ZStack { Circle().fill(accent.opacity(0.12)).frame(56×56)
             VoiceGlyph 上色 accent，约 24-26pt }
    VStack { Text("录音按键")        // 标题，16pt semibold
             subtitle }              // "长按 XX 录音 · 松手自动输入文字"
    Spacer()
    Picker(triggerKey)               // .menu 样式，占据原按钮位置
}
.padding(20).glassCard()
```

- 卡片 padding、徽章尺寸、`glassCard()` 与对话记录卡完全一致。
- 副标题沿用现有「长按 **XX** 录音 · 松手自动输入文字」富文本（含触发键加粗）。
- 触发键切换的 `onChange` 热重载逻辑原样保留。
- 右侧控件是 `Picker`（弹出菜单）而非按钮——卡片外形一致，控件按各自功能。

### 3. 替换「对话记录」卡片图标 — `MeetingTab.recordingControlCard`

- 空闲态：`Image(systemName: "record.circle")` → `DialogueGlyph` 上色 `accent`。
- 录制态：**保留** `stop.fill`（红色停止反馈不可丢失）。
- 徽章圆形底色、录制态描边圈逻辑不变。

### 4. 深浅色跟随

无需新增任何 Asset。徽章底色 `accent.opacity(0.12)`、图标色 `accent` 均来自
`ThemeManager`，已随系统外观自动切换；用户在「跟随系统/浅色/深色」三档间切换时
同样生效。

## 不做的事（YAGNI）

- 不引入 Nano Banana / 位图图标 / Asset Catalog 条目。
- 不改 `StatusBarIcon`（菜单栏图标）——本次只动设置页两张卡片。
- 不改卡片的业务逻辑（录制、热重载、Picker 绑定）。
- 不给图标做动画。

## 影响范围

| 文件 | 改动 |
|------|------|
| `Frontend/Components/BrandGlyphs.swift` | 新增 |
| `Frontend/Tabs/Sections/VoiceSettingsSection.swift` | 重排 `triggerKeyCard` |
| `Frontend/Tabs/MeetingTab.swift` | `recordingControlCard` 空闲态图标替换 |

`BrandGlyphs` 是新增的纯展示组件，无消费方耦合风险。两处卡片改动互不影响。

## 验证

- 构建通过（`xcodebuild build`），重启应用。
- 两张卡片外形尺寸一致、徽章对齐。
- 「系统设置 → 外观」切浅色/深色，或应用内主题三档切换：徽章底色与图标颜色
  随之切换，浅色不发灰、深色不发黑。
- 「对话记录」点击「开始录制」→ 图标变为 `stop.fill`，停止后回到 `DialogueGlyph`。
