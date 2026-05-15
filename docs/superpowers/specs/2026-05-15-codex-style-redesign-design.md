# Voice Bubble — Codex Style Redesign

**Date:** 2026-05-15
**Status:** Draft, awaiting user review
**Owner:** Claude (Opus 4.7)

---

## 1. Goal

把 Voice Bubble 当前的 Glassmorphism + 多主题（月光白/樱花粉/晴空蓝/墨松绿/焦糖棕）视觉语言，**整体替换**为 OpenAI Codex Mac 桌面 App 的风格，并且**只保留这一种风格**（用户原话："不要其他的风格了"）。

非目标：不改任何业务逻辑、不改协议、不改后端。改造只触及 `Frontend/`、`Shared/ThemeManager.swift` 以及 `RecordingOverlayPanel`。

---

## 2. 透彻理解 Codex 风格的设计思路

调研来源：OpenAI 官方设置文档、developers.openai.com Codex 页面、MacStories 评测、9to5Mac、DevClass、LinkedIn (Thomas Ricouard, OpenAI 工程师)、LobeHub 的 Codex brand-guidelines 技能（含权威 brand token 表）、社区截图与 GitHub issues。

### 2.1 一句话定位

Codex 不是"程序员工具"换皮，而是 **"ChatGPT 的视觉骨架，挂上 diff/terminal/agent 任务卡这些开发者面"**。它沿用了 ChatGPT.com 的色板和留白节奏，让从 ChatGPT 过来的用户立刻有家的感觉，但通过添加几个开发者专属面板和 mono 字体使用场景，建立"开发者工具"身份。

### 2.2 五个核心设计原则

**(1) Dark-first，但不是黑底白字。**
背景是温暖的近黑灰 `#0E0F12`、卡片层 `#202123`（和 ChatGPT.com 侧栏完全同色）。文字是 `#F5F7FA` 的米白色而非纯白。整个调性是**温暖深色**，不是 IDE 的纯黑高对比。

**(2) 装饰极简到几乎为零。**
没有 vibrancy、没有 glassmorphism、没有阴影（除浮动 Cmd+K palette 略带阴影）、没有动画背景气泡、没有渐变色块。OpenAI 官方在自己的 macOS native 教程里都明确说"sparingly use Liquid Glass"，结果他们自己的 Electron app 干脆完全不用。**整个界面靠类型和留白撑起精致感**。

**(3) 字体职责分离：sans 给散文，mono 给"机器输出"。**
UI 散文用系统 sans (SF Pro / -apple-system)。Mono 字体（SF Mono 优先，链是 `ui-monospace, "SFMono-Regular", "SF Mono", Menlo, Consolas, "Liberation Mono", monospace`）专门用于：终端输出、git diff、代码块、文件路径、命令面板项、热键标签。**这种 sans/mono 切分是"开发者气质"的最强信号**——比任何颜色或布局都管用。

**(4) 单一品牌强调色（OpenAI 绿 `#10A37F`），其它都是中性灰。**
主按钮（"Stage all"、"Send"）实色绿、白字。次按钮透明 + `#40434A` 边框。状态徽章（running/done/failed）用 amber/green/red 圆点 + 文字标签的胶囊形态。除此之外整个界面都是灰阶。

**(5) "小细节做精，不堆动效"。**
唯一的标志性动效是 computer-use 模式里"会扭动思考的虚拟光标"。其它转场都是普通 Electron 的 ease-in-out。OpenAI 工程师 Thomas Ricouard 自己写的 LinkedIn 文章标题就叫 *"Small details that matter"*——这就是这个产品的设计哲学：**克制的工艺感，不是炫技**。

### 2.3 Codex 与 ChatGPT 的视觉区别（区分两个目标很重要）

| | ChatGPT 桌面 | Codex 桌面 |
|---|---|---|
| 侧栏 | 单层会话列表 | **两层 Projects → Threads** |
| 中心区 | 纯对话 | 对话 + 集成终端抽屉 + composer 带文件/agent 上下文 |
| 右栏 | 没有 | **diff/review 面板**（Stage/Revert/Commit） |
| Mono 用法 | 仅代码块 | **散布全场**——终端、diff、文件路径、命令面板 |
| 强调色 | `#10A37F` | `#10A37F`（同源） |
| 吉祥物 | 无 | **8 个浮动 avatar + 虚拟光标** |

Voice Bubble 没有 chat/diff/terminal 这些场景，所以**我们抄的是 Codex 的设计词汇**（深色、mono 重用、hairline 边框、单一绿、克制动效），**不抄它的页面布局**（三栏 chat/diff/review）。

### 2.4 关键品牌 token（高置信度，来自 LobeHub Codex brand-guidelines）

| 角色 | Token | 备注 |
|---|---|---|
| Surface 1（最深底色） | `#0E0F12` | 主窗口背景，温暖近黑 |
| Surface 2（卡片/侧栏） | `#202123` | 和 ChatGPT.com 侧栏完全同色 |
| 文本主色 | `#F5F7FA` | 米白，不是纯白 |
| 文本次色/禁用 | `#9EA1AA` | 冷中灰 |
| 主强调色 | `#10A37F` | OpenAI/ChatGPT 标志绿 |
| 次强调色 | `#2B8FFF` | 链接/次 CTA 蓝 |
| Hairline 边框 | `#40434A` | 卡片/分隔细线 |

**Mono 字体栈**（GitHub openai/codex#14848 泄露）：
```
ui-monospace, "SFMono-Regular", "SF Mono", Menlo, Consolas, "Liberation Mono", monospace
```

---

## 3. Scope（改什么 / 不改什么）

### 3.1 In scope

- 删除/重置 ThemeManager 的多主题系统（`AppTheme` 枚举从 9 个 case 收敛为单一 `.codex`，但保留 ThemeManager 抽象层）
- 删除 `GlassmorphismBackground.swift`（动画气泡与 Codex 极简调性根本冲突）
- 重做 `MainWindow.swift` 的 chrome：纯色深色背景，hairline 分隔线侧栏
- 重做侧栏视觉（仍用 76px 单列 icon 但深色化、selected 状态用绿）
- 重做所有 Tab 的卡片样式（sharp corners、hairline 边框、`#202123` 填充）
- 重做 `RecordingOverlayPanel`：深色胶囊 + mono REC 标签 + 绿色波形
- 重做 toggle / button / picker / input 的视觉
- 改 `MenuBarController.swift` 的菜单栏图标和弹出面板视觉
- 删除"外观"设置项（用户不再能切主题）
- 引入"mono 字体专用"使用规则：所有热键标签、模型 ID、文件路径、转写历史的元数据、计时器数字一律用 mono

### 3.2 Out of scope（明确不做）

- 不改任何 `Backend/` 文件
- 不改 `Shared/Protocols.swift` 和 `Shared/Types.swift`
- 不删除 ThemeManager（保留作为 token 中转，仅清空 case）
- 不引入 Codex 的"avatar mascot"或"虚拟光标"——Voice Bubble 没有 agent 任务概念，强加不自然
- 不引入 ⌘K 命令面板——Voice Bubble 当前没有命令体系，不该为风格硬塞
- 不改窗口大小/最小尺寸约束（800×600）
- 不改 onboarding 流程，只换样式
- 不引入 light mode（用户说"不要其他风格"——只有 Codex dark）

### 3.3 Open question（需用户回应才能 finalize）

**Q1：是否保留"Light Codex"作为系统 dark mode 关闭时的备用主题？**
推荐：**不**。用户原话"不要其他的风格了"理解为单一暗色风格即可。如果用户系统是 light mode，应用仍强制 dark Codex。这是合理的——Codex 自己的品牌截图也几乎都是 dark。如果用户后续想要也支持 light，再加。

> **Decision (proposed default):** 强制 dark Codex，不跟随系统外观。

---

## 4. 架构决策

### 4.1 ThemeManager 单主题策略

**为什么不直接删 ThemeManager**：当前所有 View 都通过 `@EnvironmentObject ThemeManager` 拿颜色。删了等于全文件 grep-replace 几千处，出错风险大。

**采取的策略**：
1. `AppTheme` 枚举只保留 `.codex` 一个 case（`midnight` 等其它 case 完全删除）
2. 所有 `switch theme.current { ... }` 简化为直接返回 Codex 值（Swift 编译器会强制覆盖）
3. `selectableCases` 返回 `[.codex]`（避免空数组）
4. 删除"外观"设置 UI（picker 不再需要）
5. `cardDepth` 也简化为单一 `.flat`（Codex 几乎无阴影），保留枚举但只用 flat
6. `Decoration` 枚举删除（只剩 minimal 一种，没必要）

**好处**：组件代码 99% 不动，只换 token 值；以后想加 light Codex 或第二风格仍走原路径。

### 4.2 删除 GlassmorphismBackground

`MainWindow` 当前 `.background(GlassmorphismBackground().ignoresSafeArea())`，要换成 `.background(theme.windowBackground.ignoresSafeArea())`。文件 `GlassmorphismBackground.swift`（312 行）整个删除。`SeededRandomGenerator` 没有别处用，一并删。

### 4.3 调整 `glassCard()` 修饰符

`Components/ColorExtension.swift` 里的 `GlassCardModifier` 当前根据 `theme.decoration` 切三套渲染（minimal/material/expressive）。Codex 风格只需要一种：
- 圆角 6-8px（Codex 偏 sharp）
- 实色填充 `#202123`，**无 material**
- 1px hairline `#40434A` 边框
- 无阴影

简化后整个 modifier 可以从 60 行降到 ~15 行。

### 4.4 Mono 字体规则

新增一个 ViewExtension：

```swift
extension Text {
    /// Codex-style: 用于热键标签、文件路径、模型 ID、计时器、错误码等"机器内容"
    func mono(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> some View {
        self.font(.system(size: size, weight: weight, design: .monospaced))
    }
}
```

规则：以下场景**必须**用 mono——
- 录音浮窗的 `REC 00:42` 计时器
- 触发键展示（如 `⌥` Right Option）
- 模型 ID（`Qwen3-ASR-1.7B`、`gpt-4o-transcribe`）
- 历史记录里的时间戳和音频文件大小
- 替换规则的 from/to 列
- 热词标签
- 错误信息中的技术细节

其它正常 UI 文本用 sans（系统默认）。

---

## 5. Token 表（写入 ThemeManager 的最终值）

### 5.1 颜色

| 角色 | 值 | 备注 / 用途 |
|---|---|---|
| `windowBackground` | `#0E0F12` | 主窗口底色 |
| `contentBackground` | `#0E0F12` | Tab 内容背景，和窗口同色（无层级） |
| `surfaceBackground` | `#202123` | 二级面板/侧栏 |
| `cardBackground` | `#202123` | 卡片填充 |
| `inputBackground` | `#1A1B1E` | 输入框略深一档 |
| `tagBackground` | `#2A2C30` | 热词标签、徽章背景 |
| `sidebarBackground` | `#202123` | 侧栏底色 |
| `sidebarSelectedBg` | `#10A37F` 透明度 0.15 | 选中态绿色透明 |
| `border` | `#40434A` | 主 hairline |
| `borderLight` | `#2E3036` | 次级分隔线 |
| `textPrimary` | `#F5F7FA` | 主文本 |
| `textSecondary` | `#C5C7CD` | 次文本（轻读） |
| `textTertiary` | `#9EA1AA` | 弱文本 / 注释 |
| `textPlaceholder` | `#6B6E76` | 占位符 |
| `accent` | `#10A37F` | OpenAI 绿，主 CTA |
| `accentSecondary` | `#2B8FFF` | 链接 / 次 CTA |
| `warning` | `#F5A623` | amber，加载/警告 |
| `warningBackground` | `#F5A623` 透明度 0.12 | warning banner 底 |
| `warningBorder` | `#F5A623` 透明度 0.30 | warning banner 边 |
| `destructive` | `#EF4444` | 错误/删除 |
| `destructiveBackground` | `#EF4444` 透明度 0.12 | error banner 底 |
| `learningOrange` | `#F5A623` | 复用 warning（不再单独区分） |
| `successBackground` | `#10A37F` 透明度 0.12 | 就绪状态背景 |
| `cloudBadge` | `#9EA1AA` | 云端徽章（中性灰，靠 icon 区分） |
| `localBadge` | `#9EA1AA` | 本地徽章（同上） |
| `waveformColor` | `#10A37F` | 波形图主色 |
| `toggleInactive` | `#40434A` | toggle 关闭态 |

### 5.2 字体

- `fontDesign: Font.Design = .default`（系统 sans，渲染为 SF Pro / PingFang SC）
- `digitFontDesign: Font.Design = .monospaced`（Codex 在数字/计时器上用 mono）
- `bodyWeight: Font.Weight = .regular`

### 5.3 形态

- `cardBaseCornerRadius: CGFloat = 8`（Codex 偏 sharp，比当前默认 12 紧）
- `cardMaterial: Material = .regularMaterial`（实际不用 material，但保留属性兼容；GlassCardModifier 不再读 material 路径）
- `cardBorderWidth: CGFloat = 1.0`（清晰 hairline）
- `cardShadowRadius: CGFloat = 0`（无阴影）
- `cardShadowOpacity: Double = 0`

### 5.4 间距（4-pt grid，与 Codex 一致）

写入新文件 `Frontend/Components/Spacing.swift`：
```
xs:  4
sm:  8
md:  12
lg:  16
xl:  24
xxl: 32
```

侧栏宽 76（保持，icon-only 已经够 Codex）；卡片内边距 16；section 间距 24；tab 顶部内边距 32。

---

## 6. 组件级映射

### 6.1 主窗口 (`MainWindow.swift`)

- 背景：`theme.windowBackground` 实色（删除 GlassmorphismBackground）
- 侧栏：`theme.surfaceBackground` 填充，**取消圆角和阴影**（Codex 是直角侧栏 + hairline 分隔，不是浮动卡片）
- 侧栏与内容区之间用 1px `theme.border` 垂直分隔线，不再用阴影
- 顶部 traffic light 区保留 macOS 原生样式
- Permission banner / Relaunch banner：保留功能，重做视觉为深色 + amber/green hairline 边框

### 6.2 侧栏 (`MainWindow.sidebar`)

- 76px 宽不变
- 应用图标：保留圆角 9pt
- Nav item 选中态：背景 `accent.opacity(0.15)`、icon 用 `accent` 绿色
- 非选中态：icon `textTertiary` 灰
- 移除 scaleEffect 缩放动画（Codex 不用 spring 弹性）
- 改用 `withAnimation(.easeOut(duration: 0.15))`

### 6.3 卡片 (`glassCard()`)

新版统一渲染（删除 minimal/material/expressive 分支）：
```
RoundedRectangle(cornerRadius: 8)
    .fill(theme.cardBackground)        // #202123
    .overlay(
        RoundedRectangle(cornerRadius: 8)
            .stroke(theme.border, lineWidth: 1)   // #40434A hairline
    )
    // 无 shadow
```

### 6.4 按钮

新增 `Frontend/Components/CodexButtonStyles.swift`：

**主按钮**（启动服务、保存、确认）：
- 背景：实色 `accent` (`#10A37F`)
- 文字：白色，13pt semibold
- 圆角：6
- 内边距：16h × 8v
- Hover：accent 加深 8%
- Pressed：accent 加深 16%

**次按钮**（取消、设置）：
- 背景：透明
- 边框：1px `border` (`#40434A`)
- 文字：`textPrimary` 13pt regular
- 圆角：6
- Hover：背景 `tagBackground`

**危险按钮**（停止录制、删除）：
- 背景：透明
- 边框：1px `destructive` (`#EF4444`)
- 文字：`destructive`
- Hover：背景 `destructive.opacity(0.12)`

### 6.5 Toggle (`CustomToggleStyle`)

- 关闭态：track `#40434A`、thumb 白
- 开启态：track `#10A37F`、thumb 白
- 尺寸保持 44×24px
- 不要 spring（用 `.easeInOut(duration: 0.18)`）

### 6.6 输入框 / Picker

- 背景 `inputBackground` (`#1A1B1E`)
- 边框 1px `border`
- Focus：边框换 `accent`，无 glow
- 圆角 6
- 内边距 12h × 7v

### 6.7 状态徽章

热词标签 / 角标统一新组件 `CodexBadge`：
- 形态：圆角 4 的小矩形（不是 capsule）
- 内边距：8h × 3v
- 字号：11pt mono
- Variants:
  - default：bg `tagBackground`、文字 `textSecondary`
  - cloud：bg `tagBackground`、icon `cloud` + 文字 `textSecondary`（跟 Codex 一样不用色彩区分，用 icon）
  - local：bg `tagBackground`、icon `lock.shield` + 文字 `textSecondary`
  - running：bg `warning.opacity(0.15)`、文字 `warning`
  - success：bg `accent.opacity(0.15)`、文字 `accent`
  - error：bg `destructive.opacity(0.15)`、文字 `destructive`

### 6.8 录音浮窗 (`RecordingOverlayPanel`)

当前是 60×36 的圆角胶囊带毛玻璃 + 紫色波形。改造为 Codex 调性：

- 背景：实色 `#202123`，**取消 vibrancy**（NSVisualEffectView 改为普通 NSView）
  - 注意：这违反了原项目 PROJECT.md 4.4 节"录音浮窗必须用 NSPanel"的物理约束。NSPanel 仍保留（floating window level、点击穿透必须），只是底材换成实色
- 圆角：12（比窗口的 8 大一档，体现 HUD 性质）
- 波形条：颜色 `accent` (`#10A37F`)，宽度/动画参数保留
- 增加左侧"REC"标签：mono 字体，11pt semibold，红色 `destructive`，前面带闪烁圆点
- 计时器（会议模式）：`00:42` 用 mono 12pt
- 边框：1px `border`
- 阴影：`shadow(color: .black.opacity(0.4), radius: 8, y: 2)`（这是唯一保留阴影的地方——浮窗本质是 floating，需要视觉重量）

### 6.9 菜单栏图标 (`MenuBarController`)

- 图标：换为单色线条 SF Symbol `waveform`（`Image(systemName:)` 且 `.symbolRenderingMode(.monochrome)`），跟随系统模板色
- 弹出面板：用 Codex token 重做（深色背景、hairline 边框）
- 状态文字（"运行中"、"录音中"、"REC 02:35"）使用 mono 字体

### 6.10 设置 → 关于页面

- 删除"外观"设置项（picker 不再有意义）
- 保留权限状态显示
- 增加底部"About Codex Style"小字：说明此版本采用 OpenAI Codex 视觉风格
- 版本号、构建号用 mono

---

## 7. 文件级 inventory

### 7.1 新建文件

| 文件 | 用途 |
|---|---|
| `Frontend/Components/Spacing.swift` | 4pt grid 常量 |
| `Frontend/Components/CodexButtonStyles.swift` | 主/次/危险按钮 ButtonStyle |
| `Frontend/Components/CodexBadge.swift` | 状态/标签徽章 |
| `Frontend/Components/MonoTextExtension.swift` | `Text.mono()` 修饰符 |

### 7.2 重写文件

| 文件 | 改动概述 |
|---|---|
| `Shared/ThemeManager.swift` | 收敛为单一 `.codex` case，所有 token 改为 5.1 节的值，删除 9 → 1 case，删除 `Decoration` 枚举与 `decoration` 属性，删除 `bubbleColors` / `bubbleCoreOpacity` 等动画参数（背景被删了不再需要） |
| `Frontend/Components/ColorExtension.swift` | `GlassCardModifier` 简化为单一渲染分支 |
| `Frontend/MainWindow.swift` | 背景换实色、侧栏改直角 + hairline、删除 scaleEffect、按钮改用 CodexButtonStyles |
| `Frontend/Components/RecordingOverlayPanel.swift` | 实色 `#202123` 底、绿色波形、mono REC 标签 + 计时器 |
| `Frontend/Components/CustomToggleStyle.swift` | 调整颜色为 Codex token、改动画曲线 |
| `Frontend/MenuBarController.swift` | 弹出面板视觉、状态文字改 mono |
| 5 个 Tab 文件 + 4 个 Section 文件 | 替换硬编码颜色 → token、添加 mono 用法、改按钮样式调用、热词标签换 CodexBadge |

### 7.3 删除文件

| 文件 | 原因 |
|---|---|
| `Frontend/Components/GlassmorphismBackground.swift` | Codex 无装饰背景 |

### 7.4 删除代码段

- `Frontend/Tabs/AboutTab.swift` 或对应 section 中的"外观主题选择器"区块
- 所有 `theme.bubbleColors`、`theme.bubbleCoreOpacity`、`theme.bubbleGlowOpacity` 等引用
- `theme.fontDesign` 的"按主题切 serif/rounded"逻辑（永远 .default）
- 原 `cardDepth` 的 segmented control UI（保留 enum 但 UI 不再暴露）

---

## 8. 实施顺序（writing-plans 阶段会展开成分步）

1. **Token 替换**：改 ThemeManager 单主题，跑全量编译，把 switch case 收紧
2. **删除背景动画**：MainWindow 切换到实色，删 GlassmorphismBackground 文件
3. **GlassCard 简化**：替换 modifier，验证所有 Tab 视觉
4. **按钮 / Toggle / Badge 新组件**：先建组件库
5. **Tab 逐个迁移**：5 个 Tab + 4 个 Section 改用新组件和 token
6. **Mono 字体规则落地**：在指定字段用 `.mono()`
7. **录音浮窗重做**：实色底 + 绿波形 + mono REC
8. **菜单栏重做**：弹出面板视觉
9. **删除外观设置 UI**
10. **构建 + 重启 + 端到端目视**

---

## 9. 风险与回归红线

1. **NSPanel 实色 vs vibrancy**：当前浮窗用 vibrancy 是为了视觉融入桌面，换实色后在浅色桌面上会显得突兀。但 Codex 风格本来就是"硬质 HUD"，这是预期效果。**红线**：仍要保证 floating level、点击穿透、不抢焦点（PROJECT.md 4.4 的硬约束）。
2. **删除 ThemeManager 的多 case 后旧用户配置**：UserDefaults 里可能存着 `appTheme = "sakura"`。`init()` 里要把所有非 `.codex` 的 raw value 兜底到 `.codex`。
3. **PingFang SC 与系统 dark mode**：强制 dark 时，PingFang 在某些 macOS 版本上字重渲染会偏细。**红线**：在 macOS 14、15、16 上目视确认中文字号 13/12pt 都清晰可读。
4. **录音浮窗实色底 + traffic light 区**：浮窗在屏幕顶部居中，不会和 traffic light 冲突，无问题。
5. **菜单栏图标在 light 系统下**：菜单栏图标必须 `.symbolRenderingMode(.template)` 让系统接管 dark/light 反色，否则会在浅色菜单栏隐形。
6. **历史记录 / 会议纪要里大量小字**：mono 用太多会有 IDE 感。规则严格执行 6.1—6.7 列表，**散文一律 sans**。

---

## 10. 验证清单

- [ ] 启动应用，主窗口背景是 `#0E0F12` 纯色
- [ ] 五个 Tab 内容呈现 `#202123` 卡片 + `#40434A` hairline
- [ ] 侧栏选中态显示绿色背景透明 + 绿色 icon
- [ ] 触发键标签显示为 mono "⌥ Right Option"
- [ ] 模型 ID `Qwen3-ASR-1.7B` 显示为 mono
- [ ] 录音时浮窗显示绿色波形 + mono "REC" + 红色闪烁点
- [ ] 会议录制时浮窗显示 mono 计时器 `00:42`
- [ ] 主按钮（启动服务）实色绿底白字
- [ ] Toggle 开启态绿色 track
- [ ] 关于页面没有"外观"主题选择器
- [ ] 菜单栏图标在 light/dark 系统下都可见
- [ ] 旧用户从 `sakura` 主题升级后自动落到 `codex`，不报错
- [ ] 所有原有功能（录音、识别、粘贴、会议、热词、替换规则、历史）行为不变

---

## 11. Open Questions（待用户确认）

1. **是否保留"跟随系统外观"作为隐藏开关？** 当前提案是强制 dark Codex（不跟随系统）。
2. **是否需要为 PingFang SC 中文字号特调？** 提案是不调，沿用系统默认。
3. **Codex 浮窗背景实色后，是否在浮窗下增加额外阴影以拉开和桌面的层级？** 提案是加 8px 黑色 0.4 阴影（6.8 节）。
4. **是否需要把 mono 字体范围扩大到所有"数字显示"（包括滑块旁的字号 18 等普通数字）？** 提案是只用于"机器输出"语义场景（计时器、ID、热键、文件路径等），不机械化覆盖所有数字。

---

## 12. 决策日志

| 决策 | 理由 |
|---|---|
| 保留 ThemeManager 抽象，单一 case | 避免改千行 View 代码；保留扩展性 |
| 删除 GlassmorphismBackground | Codex 完全无装饰背景，气泡和它不可调和 |
| 不引入 ⌘K 命令面板 | Voice Bubble 没有命令体系，硬塞会破坏简洁 |
| 不引入 mascot avatar | 同上，无 agent 任务概念 |
| 强制 dark，不跟随系统 | 用户原话"不要其他风格"理解为单一 dark Codex |
| 浮窗换实色但保留 NSPanel | 视觉对齐 Codex，物理约束（floating/穿透）必须保留 |
| Mono 用法严格列表化 | 防止"IDE 感"过度，保留 ChatGPT 那种从容感 |

---

## 13. 后续步骤

此 spec 经用户审阅后，交付 `superpowers:writing-plans` skill 展开为分步实施计划。
