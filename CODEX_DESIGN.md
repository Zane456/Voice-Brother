# Codex Design — 完整规范（从 Codex.app 拆出来）

来源：`/Applications/Codex.app/Contents/Resources/app.asar` → `webview/assets/`
Codex 版本：`26.513.20950`（OpenAI 官方 Electron 应用）
拆包时间：2026-05-15

> 此文档替代 `06cf438 spec: Codex-style redesign`。之前那份 spec 是**基于截图猜测**写的，"深色 + 绿色 accent + mono 数字"全是误判。真实的 Codex 是 **light/dark 双主题 + 蓝色 accent + 全 sans + Tailwind v4 体系**。

---

## 0. 一句话总结

Codex 不是"黑色 Geek 风"，而是 **OpenAI 现代企业产品风**：
- **light 是默认**（macOS 通常跟随系统）
- **白底 + 8% 灰发丝线**做结构分隔，几乎没有阴影
- **#339CFF 蓝色 accent**（不是绿，不是黑）
- **near-black 填充按钮**（视觉上像黑色 accent，其实是文本前景色的复用）
- **全 sans，仅代码块用 mono**
- **极克制的动画**（0.15s basic / 0.3s relaxed + `cubic-bezier(.19,1,.22,1)` 主缓动）
- **圆角阶梯丰富**（2px-24px 共 9 档）

---

## 1. 与现有代码的差异速查（critical fixes）

| 维度 | 当前代码（错的） | Codex 实际（对的） | 影响文件 |
|---|---|---|---|
| 主题模式 | 只有 dark | light + dark 双主题 | `ThemeManager.swift` |
| 默认 | dark `#0E0F12` | macOS 系统默认 = light | `MainWindow.swift:103` |
| Accent | `#10A37F` 绿 | **`#339CFF` 蓝** | 全局搜替换 |
| 字体 | sans + 数字 mono | **全 sans**，mono 只配代码 | 见 §11 撤回清单 |
| 卡片圆角 | 8px 固定 | 阶梯：2/4/6/8/10/12/16/20/24 | `glassCard()` |
| 卡片填充（dark） | `#202123` | `#282828`（gray-750） | `cardOverlayColor` |
| 主背景（light） | — | `#FFFFFF` (gray-0) | 全部 background |
| 主背景（dark） | `#0E0F12`（太黑） | `#181818` (gray-900) | 同上 |
| 卡片阴影 | 无（这点对了） | 仅 dropdown 用 shadow-2xl | 现有逻辑保留 |
| 边框 | `#40434A` 固定灰 | **8% 的前景色**（自动适配主题） | `border` token |
| 动画曲线 | 默认 ease-out | **`cubic-bezier(.19,1,.22,1)`** | Animation |
| 动画时长 | 0.25s 固定 | **0.15s 基础 / 0.3s 缓和** | Animation |
| Primary 按钮 | accent 绿填充 | **near-black 填充 + 白字** | `CodexPrimaryButtonStyle` |

**最大的认知错误**：截图里发送按钮看着黑，不是因为 accent 是黑色，而是 Codex 的 primary 按钮风格就是"用 `--color-text-foreground` 做填充 + 反色文字"。Accent（focus ring、链接、icon-accent、selected）始终是蓝色 `#339CFF`。

---

## 2. 基础色阶

```
--gray-0     #FFFFFF   light 主背景
--gray-50    #F9F9F9   light 侧栏底
--gray-100   #EDEDED   light 输入弱底
--gray-300   #AFAFAF   placeholder / 占位文字
--gray-500   #5D5D5D
--gray-550   #4F4F4F
--gray-600   #414141
--gray-700   #303030
--gray-750   #282828   dark 卡片 (elevated-primary)
--gray-800   #212121   dark elevated-secondary / 编辑器底
--gray-900   #181818   dark 主背景
--gray-1000  #0D0D0D   最深，dark 主题的 primary 按钮填充

--blue-50    #E5F3FF   light accent 弱底
--blue-100   #99CEFF   dark 主题文字 accent
--blue-300   #339CFF   ★品牌 accent，focus ring, icon-accent
--blue-400   #0285FF
--blue-900   #00284D   dark accent 弱底

--green-500  #16A34A   success icon/text
--orange-500 #F97316   warning
--red-500    #EF4444   error
--yellow-500 #EAB308
```

绿/橙/红/黄只用于状态（success/warning/error/info），**不参与品牌**。

## 3. 语义 Token

### Light 主题

```
text-foreground            #1A1C1F                主文本（不是纯黑！有冷调）
text-foreground-secondary  #1A1C1F @ 70%
text-foreground-tertiary   #1A1C1F @ 50%
text-placeholder           #AFAFAF (gray-300)
text-accent                #339CFF (blue-300)
text-button-primary        #FFFFFF (gray-0)
text-button-secondary      #1A1C1F (foreground)
text-button-tertiary       #5D5D5D (gray-500)
text-success               #16A34A (green-500)
text-warning               #F97316 (orange-500)
text-error                 #EF4444 (red-500)

background-surface              #FFFFFF (gray-0)   主区域底
background-surface-under        #F9F9F9 (gray-50)  侧栏底
background-elevated-primary     #FFFFFF @ 70%       浮层弱（带模糊背景）
background-elevated-primary-opaque #FFFFFF          浮层强
background-elevated-secondary   #1A1C1F @ 2%        次级 elevation
background-button-primary       #1A1C1F (foreground)  主按钮填充
background-button-primary-hover #1A1C1F @ 92%
background-button-primary-active #1A1C1F @ 84%
background-button-secondary     #1A1C1F @ 5%
background-button-tertiary      transparent
background-accent               #E5F3FF (blue-50)    accent 弱底
background-status-success       #16A34A @ 7%
background-danger               #EF4444 @ 10%

border                          #1A1C1F @ 8%        发丝线（默认）
border-heavy                    #1A1C1F @ 12%       强发丝线
border-light                    #1A1C1F @ 5%        弱发丝线
border-focus                    #339CFF (blue-300)
border-error                    #EF4444 @ 15%
border-warning                  #F97316 @ 15%

icon-primary                    #1A1C1F (foreground)
icon-secondary                  #1A1C1F @ 70%
icon-tertiary                   #1A1C1F @ 50%
icon-accent                     #339CFF (blue-300)
icon-success                    #16A34A
icon-warning                    #F97316
icon-error                      #EF4444
```

### Dark 主题

```
text-foreground            #FFFFFF (gray-0)
text-foreground-secondary  #FFFFFF @ 70%
text-foreground-tertiary   #FFFFFF @ 50%
text-accent                #99CEFF (blue-100)        ← dark 提亮
text-button-primary        #0D0D0D (gray-1000)        ← 按钮里的白圆按了反色

background-surface              #181818 (gray-900)
background-surface-under        sidebar 单独（通常 #121212）
background-elevated-primary-opaque  #282828 (gray-750)  ← 卡片
background-elevated-secondary-opaque #212121 (gray-800)
background-button-primary       #0D0D0D (gray-1000)    ← 主按钮（白底白圆）
background-button-secondary     #FFFFFF @ 5%
background-button-tertiary      #FFFFFF @ 3%
background-accent               #00284D (blue-900)

border                          #FFFFFF @ 8%
border-heavy                    #FFFFFF @ 16%
border-light                    #FFFFFF @ 4%
border-focus                    #339CFF @ 70%

icon-primary                    #FFFFFF @ 90%
icon-secondary                  #FFFFFF @ 70%
icon-tertiary                   #FFFFFF @ 50%
icon-accent                     #339CFF (blue-300)
```

---

## 4. Typography

```
--font-sans   系统默认（macOS: SF Pro / 中文 PingFang SC）
--font-mono   仅代码块/编辑器（vscode-editor-font-family）

--text-xs     11px    辅助标签（侧栏快捷键、徽章里的微型文字）
--text-sm     12px    次级文本、卡片描述
--text-base   14px    正文、侧栏 item、按钮文字（默认）
--text-lg     16px    强调正文
--text-xl     28px    页面标题（截图里的"我们该在 LCR 平衡 中做什么？"）
--text-2xl    36px    大型标题
--text-3xl    48px    Hero 标题

--font-weight-light       300
--font-weight-normal      400  默认
--font-weight-medium      500  侧栏选中态、徽章
--font-weight-semibold    600  按钮、section header
--font-weight-bold        700  极少用
```

**规则**：
- UI chrome 100% 用 sans
- Mono 只出现在：代码块、终端输出、diff 视图、shell command 内嵌
- 数字（计时器、版本号、percent）**不强制 mono**——这是当前 Voice Brother 误判
- 数字需要等宽对齐时用 `font-variant-numeric: tabular-nums` 即可，不必换字体

---

## 5. Motion / Animation

### 持续时长 tokens

```
--transition-duration-basic     0.15s   微交互（hover、按下、focus 进入）
--transition-duration-relaxed   0.30s   面板出现、tab 切换、抽屉
```

### 缓动 tokens

```
--cubic-enter         cubic-bezier(.19, 1, .22, 1)   ★ 主进入（强 ease-out）
--cubic-exit-snappy   cubic-bezier(.65, 0, .4, 1)    退出（轻微 in-out）
```

观察到的其他高频曲线：
- `cubic-bezier(.22, 1, .36, 1)` — referral modal 用，更柔和的 ease-out
- `cubic-bezier(.4, 0, .2, 1)` — Material standard，少量用
- `cubic-bezier(.16, 1, .3, 1)` — radix dropdown，与 cubic-enter 几乎一样

### 关键交互动画

| 行为 | 时长 | 曲线 |
|---|---|---|
| 按钮 hover/active 色变 | 0.15s | basic / linear |
| Dropdown 进入 | 0.15s | `cubic-enter` + opacity 0→1 + scale 0.98→1 + translateY 2px→0 |
| Dropdown 退出 | 0.15s | `cubic-exit-snappy` |
| Tab 切换 | 0.3s | `cubic-enter` |
| Sidebar 折叠/展开 | 0.3s | `cubic-enter` |
| Modal 出现 | 0.32s opacity / 0.52s transform | `cubic-bezier(.22,1,.36,1)` |
| Toast 进入 | 0.22s | ease-out |
| Loading shimmer | 1s 周期 | `steps(48, end)` 锯齿步进，不是平滑 |

### Reduced-motion

`@media (prefers-reduced-motion: reduce)` 必须实现：所有 transform/opacity 都降到 0.22s ease-out，长动画（>0.4s）改为 instant。

### Voice Brother 当前问题

- `fdb7f46` toggle 已经用 ease-out 是对的 ✓
- 但通用 transition 时长用了 0.25s（应该是 0.15 或 0.3，不是中间值）
- 没有用 `cubic-bezier(.19,1,.22,1)` 这个标志性曲线

---

## 6. Spacing / Radius / Shadow

### Spacing

`--spacing: 0.25rem = 4px`，所有 padding/margin 都是 4 的倍数。

常用规约：
```
padding-row-x     spacing × 2     8px     列表 item 水平 padding
padding-row-y     spacing × 1.25  5px     列表 item 垂直 padding
padding-panel     spacing × 5     20px    panel/卡片内 padding
padding-panel/2   spacing × 2.5   10px    紧凑 panel
```

### Radius

```
--radius-2xs    2px      tag 角
--radius-xs     4px      input 内的小元素
--radius-sm     6px      icon button、徽章
--radius-md     8px      默认按钮
--radius-lg     10px     卡片（标准）
--radius-xl     12px     大卡片
--radius-2xl    16px     输入框、modal（截图里主输入是这个）
--radius-3xl    20px     command menu
--radius-4xl    24px     大型对话气泡
--radius-full   9999px   pill / 头像 / circular button
```

### Shadow

```
--shadow-md     0px 2px 4px -1px #00000014   ← 仅 tooltip 用
--shadow-xl     0px 8px 16px -4px #0000001F  ← popover 用
--shadow-2xl    0px 16px 32px -8px #00000030 ← command menu / 模态
```

**默认无阴影**。只有浮起的、可点击外区域关闭的元素才上阴影。卡片、侧栏、按钮全部用发丝线分层。

---

## 7. 窗口结构（layout）

```
┌──────────────────────────────────────────────────────────────┐
│ ←── 侧栏 ~260px ──→│ ←── 主区域 ─────────────────────────→  │
│ #F9F9F9 (gray-50)  │ #FFFFFF (gray-0)                       │
│                    │                                         │
│ ●●● ⌐ 整个高度    │  ⌐ traffic light 区域属于主区域         │
│      ↑ 含 traffic │                                         │
│       light 区     │                                         │
└──────────────────────────────────────────────────────────────┘
                    ↑ 1px #1A1C1F @ 8% 垂直发丝线
```

**关键**：
- 侧栏从窗口最顶（包含 traffic light 区域）一直延伸到底
- 整个窗口 `WindowControlsHidden + .titleBar(.hidden) + .windowToolbarStyle(.unified)`
- 没有 macOS 系统的 sidebar `NSVisualEffectView` 模糊，是纯色 `#F9F9F9`
- 侧栏与主区之间是 **1px 实色发丝线**，不是 SwiftUI 默认的 `.divider`
- 主区域内容**居中 + 收窄到 max-width ≈ 720px**（截图里的输入框和卡片都是这个宽度），左右留白

### 主区域内边距

```
.thread-content-top-inset      spacing × 8 = 32px
.thread-content-max-width      480-500px（消息流） / 720px（首页 hero）
.sectioned-page-leading-inset  0-12px（侧栏向右贴边的灰边）
```

---

## 8. 组件模式

### 8.1 侧栏 item

```
┌─────────────────────────────────────┐
│  ◯  新对话                     ⌘N  │  ← 高度 32-36px
└─────────────────────────────────────┘
   ↑ 14×14 icon, 8px 间距
   ← 整行 padding：水平 12px，垂直 6px
   ← 圆角 6px (radius-sm)
   ← 选中态背景：blue-50 (light) / blue-900 (dark)
   ← hover 态背景：foreground @ 5%
   ← 文字 14px regular，选中时 medium
```

**项目分组**（"项目"那种 section header）：
- 文字 12px (text-sm)
- 颜色 `text-foreground-tertiary` = foreground @ 50%
- 左 padding 与 item 对齐，上下间距 8-12px
- **不是粗体**，不全大写

**项目子项**（"查找可删除废弃文件 ⌘1"）：
- 与父项目同行高
- 左 padding 增加 24px 缩进
- 右侧快捷键：`text-xs` 11px + tertiary color，右对齐

### 8.2 主按钮（primary）

```
┌──────────────────┐
│   立即重启       │   ← 高度 28px (sm) / 32px (default) / 40px (lg)
└──────────────────┘
   ← bg: text-foreground (#1A1C1F light / #0D0D0D dark)
   ← text: gray-0 (#FFFFFF)，14px semibold
   ← padding 水平 12px，垂直 6px
   ← 圆角 8px (radius-md)
   ← hover: bg 透明度从 100% → 92%
   ← active: bg 透明度 → 84%
   ← disabled: opacity 0.5
```

### 8.3 次级按钮（secondary）

```
┌──────────────────┐
│   去授权         │
└──────────────────┘
   ← bg: foreground @ 5%
   ← text: foreground，14px medium
   ← hover: bg foreground @ 5% → 8%
   ← active: bg → 12%
```

### 8.4 输入框（composer）

```
┌─────────────────────────────────────────────╮
│ 可向 Codex 询问任何事。输入 @ 使用插件...    │   ← 圆角 16px (radius-2xl)
│                                              │   ← bg #FFFFFF
│ + 自动审查  ▼              5.5 超高  🎤  ↑ │   ← border 1px @ foreground 8%
╰─────────────────────────────────────────────╯   ← 内 padding 水平 16 垂直 12
                                                   ← focus 时 border-focus + 微弱外发光
                                                   ← 多行可扩展，min-height 56px
```

底部那一行（composer footer）是**容器查询布局**：
- `container-type: inline-size`
- 宽度 < 300px 时折叠次级 chip 文字、只保留 icon
- 宽度 < 420px 时折叠 chevron

### 8.5 Action 卡片（"连接消息传送"那种）

```
┌──────────────┐
│  ⌘ Slack    │   ← 高度自适应，min 120px
│              │   ← bg #FFFFFF，border 1px @ 8%
│  连接消息传送│   ← 圆角 10px (radius-lg)
│  从近期团队  │   ← padding 16px
│  讨论中获取..│   ← title 14px medium, desc 12px secondary
│              │   ← hover: bg foreground @ 2%
└──────────────┘
```

### 8.6 Dropdown menu

```
┌─────────────────┐
│  ✓ Light        │
│    Dark         │
│ ───────────────│  ← 分组线 border @ 5%
│    Auto         │
└─────────────────┘
   ← bg #FFFFFF + shadow-xl + border 1px @ 8%
   ← 圆角 12px (radius-xl)
   ← item 高度 28-32px，圆角 10px (radius-lg)
   ← item hover: bg foreground @ 5%
   ← 出现动画：scale 0.98→1 + translateY 2px→0 + opacity 0→1 over 0.15s cubic-enter
```

### 8.7 Toggle / Switch

观察 Codex 内部页面：使用 native 风格 toggle，**轨道色 = foreground @ 12%（off）/ #1A1C1F（on，foreground 满色）**。
不是绿色 ✗，不是蓝色 ✗。

当前 Voice Brother 的 toggle (`fdb7f46`) 用了绿色轨道，需要改成 foreground 色。

### 8.8 徽章 / Badge

```
┌────────┐
│ ● 已连接│   ← 高度 20-24px
└────────┘
   ← bg accent 弱底（blue-50 / blue-900）或 status 弱底
   ← border: 通常没有，靠弱底色区分
   ← 圆角 6px (radius-sm) 或 full (pill)
   ← text-xs 11px，semibold
   ← 点（status dot）8×8px circle
```

### 8.9 Loading / 思考态（thinking shimmer）

Codex 用的不是 spinner，是**文字 shimmer**：
- 文字本体 `color: secondary`
- 50% 宽度 mask 从左向右扫过，揭露 `color: foreground` 的高对比版本
- 周期 1s，`animation-timing-function: steps(48, end)`（**锯齿步进**，不是平滑）
- reduced-motion 时关闭

这是 OpenAI 标志性的"打字思考"动画，Voice Brother 的 "转写中..." 可以借鉴。

---

## 9. 状态系统

每个交互元素必须实现五态：

| 状态 | 视觉变化 |
|---|---|
| **default** | 基础样式 |
| **hover** | bg 加 5-8%、color 不变；transition 0.15s linear |
| **active** | bg 加 10-16%；transition 0.15s |
| **focus-visible** | 2px ring `border-focus` @ 70% + offset 2px；不用 default browser ring |
| **disabled** | opacity 0.5；pointer-events: none；保留颜色不变灰 |
| **loading** | shimmer 文字 + 禁用点击 |

**关键**：Codex 用**透明度叠加**（color-mix oklab 不是 srgb）实现状态，所以在 light/dark 都自动正确。

---

## 10. Icon 系统

观察截图与代码：
- **线性 icon 风格**（lucide-react 类似）
- 1.5px stroke
- 16×16 (text-base 行) / 14×14 (sidebar item) / 20×20 (按钮内独立)
- **不混用 filled 和 outlined**
- 不用 emoji 当 icon（emoji 仅在徽章/装饰用）

SwiftUI 等价：
- 默认用 `Image(systemName: ...)` SF Symbols
- **`.font(.system(size: 16, weight: .regular))`** ，不要 `.bold` 让线变粗
- 不要用 `.fill` 后缀的图标（如 `gearshape.fill`），用 outlined（`gearshape`）

当前 `MainWindow.swift:230` 的 navItem 在 selected 时切到 `.semibold` —— Codex 也这么干，**保留**。

---

## 11. Voice Brother 撤回清单（mono 误用）

把以下 commit 的 mono 改动**撤销**或**改为 tabular-nums**：

| Commit | 改动 | 处理 |
|---|---|---|
| `8b5472e` menubar REC timer mono | 撤销，改用 `Font.system(size:design:.default).monospacedDigit()` |
| `527371f` provenance badges + banner buttons + timer/version mono | 撤销 badge/button mono；timer/version 保留 `monospacedDigit()` |
| `8fcb5ac` overlay 的 mono REC | 撤销 |
| `fdb7f46` 绿色 toggle | accent 绿改 foreground 色（near-black） |
| `635e08b` 单 Codex 主题 | 改回支持 light/dark，默认 system |

```swift
// 错的（当前）
Text("\(seconds)").font(.system(size: 13, design: .monospaced))

// 对的
Text("\(seconds)")
    .font(.system(size: 13))
    .monospacedDigit()  // 仅数字等宽，字母仍 sans
```

---

## 12. 录音浮窗（RecordingOverlayPanel）适配

跟随系统主题。结构保持，颜色改：

| 部位 | Light | Dark |
|---|---|---|
| 浮窗 bg | `#FFFFFF` @ 95% + 8px backdrop-blur | `#181818` @ 95% + blur |
| 边框 | `#1A1C1F @ 8%` 1px | `#FFFFFF @ 8%` 1px |
| 阴影 | shadow-2xl | shadow-2xl（dark 用 50% 不透明度） |
| 文本 | `#1A1C1F` | `#FFFFFF` |
| 波形 | **`#339CFF` blue-300**（不是绿！） | `#339CFF` |
| REC 红点 | `#EF4444` | `#EF4444` |
| 圆角 | 16px (radius-2xl) | 16px |

考虑：浮窗叠在屏幕上时**永远会有亮/暗背景对比问题**。Codex 自己的 thinking 浮层（dropdown）用 95% 不透明 + blur 解决——即使在亮背景上的暗浮窗，blur 也能维持可读性。建议跟随系统不要 force dark。

---

## 13. 字体/数字处理细节（macOS 特化）

```swift
// 在 Voice Brother 里需要"等宽数字"但不要 mono 字体的地方：
Text(String(format: "%02d:%02d", min, sec))
    .font(.system(size: 14))
    .monospacedDigit()             // ← 这是关键 API
    .fontDesign(.default)          // 显式回到 sans

// 真要 mono 字体的地方（代码块、终端预览）：
Text(code)
    .font(.system(size: 13, design: .monospaced))
```

`.monospacedDigit()` 是 SwiftUI 直接支持的，效果等同 CSS `font-variant-numeric: tabular-nums`：字母按比例宽度，数字等宽。这正是 Codex 的做法。

---

## 14. ThemeManager 重写要点

```swift
enum AppTheme: String, CaseIterable, Codable {
    case system    // 默认；跟随 NSApp.effectiveAppearance
    case light
    case dark

    var displayName: String { ... }
}

final class ThemeManager: ObservableObject {
    @Published var current: AppTheme = .system

    /// 监听系统外观切换
    private var appearanceObserver: NSKeyValueObservation?

    /// 实际生效的 isDark（计算属性，不持久化）
    @Published private(set) var isDark: Bool = false

    init() {
        observeSystemAppearance()
    }

    private func observeSystemAppearance() {
        let app = NSApp ?? NSApplication.shared
        appearanceObserver = app.observe(\.effectiveAppearance) { [weak self] _, _ in
            self?.recomputeIsDark()
        }
        recomputeIsDark()
    }

    private func recomputeIsDark() {
        switch current {
        case .light: isDark = false
        case .dark:  isDark = true
        case .system:
            isDark = NSApp.effectiveAppearance.bestMatch(
                from: [.darkAqua, .aqua]
            ) == .darkAqua
        }
    }

    // —— Tokens ——

    var windowBackground: Color   { isDark ? hex(0x181818) : hex(0xFFFFFF) }
    var sidebarBackground: Color  { isDark ? hex(0x121212) : hex(0xF9F9F9) }
    var surfaceBackground: Color  { isDark ? hex(0x282828) : hex(0xFFFFFF) }
    var textPrimary: Color        { isDark ? .white : hex(0x1A1C1F) }
    var textSecondary: Color      { textPrimary.opacity(0.70) }
    var textTertiary: Color       { textPrimary.opacity(0.50) }
    var accent: Color             { hex(0x339CFF) }
    var border: Color             { textPrimary.opacity(0.08) }
    var borderHeavy: Color        { textPrimary.opacity(isDark ? 0.16 : 0.12) }
    var borderFocus: Color        { accent.opacity(isDark ? 0.70 : 1.00) }

    // —— Radii ——
    let radiusSm:  CGFloat = 6
    let radiusMd:  CGFloat = 8
    let radiusLg:  CGFloat = 10
    let radiusXl:  CGFloat = 12
    let radius2xl: CGFloat = 16

    // —— Motion ——
    let durationBasic: Double = 0.15
    let durationRelaxed: Double = 0.30
    var easeEnter: Animation { .timingCurve(0.19, 1.0, 0.22, 1.0, duration: durationBasic) }
    var easeExitSnappy: Animation { .timingCurve(0.65, 0.0, 0.4, 1.0, duration: durationBasic) }
}
```

---

## 15. 实施顺序（独立可验证步骤）

每一步独立提交、构建、重启 app 看效果，**不要堆改**。

1. **重建 ThemeManager**：双主题 + 跟随系统监听（§14）
2. **替换 accent**：全局 `#10A37F` → `#339CFF`
3. **撤回 mono 误用**：按 §11 表格，把 timer/version 改 `.monospacedDigit()`，banner/button 撤 mono
4. **背景色翻转**：light 模式下 `windowBackground`/`contentBackground` → `#FFFFFF`
5. **侧栏色**：light `#F9F9F9` / dark `#121212`，垂直发丝线保留
6. **卡片填充翻转**：light `#FFFFFF` + 8% 边框 / dark `#282828` + 8% 边框
7. **Primary 按钮**：bg 改为 `textPrimary`（near-black），文字反色为白
8. **Toggle 颜色**：绿轨道改为 `textPrimary` 满色（on）/ `borderHeavy`（off）
9. **波形色**：绿改 `#339CFF`（VoiceService + MeetingService 都要改）
10. **录音浮窗**：跟主题切（§12）
11. **动画曲线**：transition 改为 `easeEnter`（cubic-bezier(.19,1,.22,1)），时长 0.15/0.30
12. **圆角调整**：卡片从 8px 改 10px (`radiusLg`)；输入框 16px (`radius2xl`)

每步验证：
```bash
cd "/Users/zhangzheng/IDE project/Voice Brother"
xcodebuild build -project VoiceBrother.xcodeproj -scheme VoiceBrother -quiet
pkill -x "VoiceBrother" 2>/dev/null || true
open "/Users/zhangzheng/Library/Developer/Xcode/DerivedData/VoiceBrother-arbvxvbxxsnfymbulsnszkqkgdon/Build/Products/Debug/VoiceBrother.app"
```

---

## 16. 拆包 artifacts（如需复查）

```
拆包目录: /tmp/codex_extract/
主 CSS:    /tmp/codex_extract/webview/assets/app-main-Bc-fuGhR.css   (~5 MB)
Composer:  /tmp/codex_extract/webview/assets/composer-0WIQtlLp.css
Dropdown:  /tmp/codex_extract/webview/assets/dropdown-WLGrgMtf.css
Shimmer:   /tmp/codex_extract/webview/assets/thinking-shimmer-83dxNCp_.css
原 asar:   /Applications/Codex.app/Contents/Resources/app.asar
```

如需重新拆包：
```bash
npx --yes @electron/asar extract \
  /Applications/Codex.app/Contents/Resources/app.asar \
  /tmp/codex_extract/
```
