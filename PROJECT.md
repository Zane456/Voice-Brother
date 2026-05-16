# Voice Brother - 项目文档

> 本文档是 Voice Brother 的完整需求定义。任何 AI 助手在参与本项目时，应首先阅读此文档以获取完整上下文。

## 一、项目概述

**Voice Brother** 是一款 macOS 原生语音输入应用，使用 Swift/SwiftUI 构建。它是 Voice Aura（Python/Tkinter 版本）的全面重制版，核心目标不变：**按住键说话，松开后文字自动输入到光标位置**。

### 为什么重制

Voice Aura 使用 Python + Tkinter + PyTorch 构建，功能完整但存在以下局限：
- 需要 Python 环境，无法作为独立 .app 分发
- Tkinter 非原生 UI，在 macOS 上观感不够精致
- PyTorch 模型占用大，启动慢

Voice Brother 采用 Swift + SwiftUI + MLX，实现完全原生的 macOS 应用体验。

### 前身项目参考

- **Voice Aura**（Python 版）：位于 `~/IDE project/Voice-Aura/`，所有现有功能均需在 Voice Brother 中重现
- **Type4Me**（joewongjc/type4me）：UI 布局参考，左侧导航栏 + 右侧内容面板的设置界面结构
- **TypeNo**（marswaveai/TypeNo）：极简交互参考

---

## 二、核心功能

### 2.1 语音输入（主功能）

用户按住配置的触发键开始录音，松开后自动识别语音并将文字输入到当前光标位置。

**录音触发**：
- 支持的触发键：右 Command（默认）、左 Command、右 Option、左 Option、Control、Shift
- 触发方式：按住录音（hold-to-record）
- 按下触发键 → 开始录音 → 显示录音浮窗
- 松开触发键 → 停止录音 → 识别 → 输入文字 → 隐藏浮窗

**语音识别**：
- 使用 Qwen3-ASR 模型（通过 speech-swift 库 / MLX 推理）
- 两种模型规格：
  - Qwen3-ASR-0.6B（极速模式，约 680MB）
  - Qwen3-ASR-1.7B（精确模式，约 2.5GB）
- **首次启动时两个模型都自动下载**，下载过程显示进度（先下载当前选择的模型，再后台下载另一个）
- 用户可在设置中切换使用哪个模型，切换时无需等待下载

**文字输入**：
- 识别完成后，将文字写入剪贴板并模拟 Cmd+V 粘贴
- **必须保护剪贴板**：粘贴前保存原有剪贴板内容，粘贴后恢复
- 支持所有剪贴板数据类型（文字、图片、文件等）

**文字后处理**（按顺序执行）：
1. **语气词过滤**（可开关）：
   - 先删除词汇：逐个替换"呃"、"额"、"嗯"、"啊啊"、"哎"为空
   - 再清理标点（正则必须匹配全角+半角）：`[，,]{2,}` → `，`、`[。.]{2,}` → `。`
   - 再去除开头标点（含顿号）：`^[，,。.、]+` → 删除
   - 最后 trim 首尾空白
2. **替换规则**：对识别结果逐条执行字符串替换（如 "cloud code" → "Claude Code"），按配置中的顺序
3. **热词（Hotwords）**：所有热词用空格拼接成一个字符串，作为 `context` 参数传给 ASR 模型的 `transcribe()` 调用，同时固定传 `language="Chinese"`

> 注意：会议纪要的转写**只执行语气词过滤**，不执行替换规则，也**不传递热词/context 参数**给 ASR 模型。这是有意的设计——会议内容应保留原始表述。

**录音中的空格重定位**：
- 录音过程中按空格键 → 在鼠标当前位置执行一次点击（CGEvent 模拟 mouseDown+mouseUp）
- 用途：录音中途切换文字输入位置
- 此功能可通过设置开关
- 实现细节：空格键的 keyDown 事件被拦截（返回 nil，不传递给目标应用），对应的 keyUp 也必须拦截。如果功能关闭，空格正常传递

**语音输入完整数据流**：
```
用户按下触发键
  → KeyboardListener 检测到 keyDown 事件
  → 通知 VoiceService: "开始录音"
  → VoiceService 启动音频流（AVAudioEngine, 16kHz, mono, Float32）
  → 显示录音浮窗（overlay.show）
  → 音频 buffer 持续写入内存数组

用户松开触发键
  → KeyboardListener 检测到 keyUp 事件
  → 通知 VoiceService: "停止录音"
  → 隐藏录音浮窗（overlay.hide）
  → 音频 buffer 合并为完整音频数据
  → 调用 Qwen3ASR.transcribe(audio:sampleRate:) 进行识别
  → 对识别结果进行后处理：
      1. 去除语气词（如开启）
      2. 应用替换规则
  → 调用 TextInjector.typeText(text)：
      a. 保存当前剪贴板内容（NSPasteboard 所有 item 的所有 type）
      b. 将识别文字写入剪贴板
      c. CGEvent 直接发送 Cmd+V（keyDown + keyUp, virtualKey=0x09）
      d. 等待 200ms
      e. 恢复原剪贴板内容
```

### 2.2 会议纪要

长时间录制系统音频和麦克风，自动分段转写，输出带时间戳的 Markdown 文件。

**音频采集**：
- 同时捕获系统音频（ScreenCaptureKit, 48kHz mono）和麦克风音频（AVAudioEngine, 16kHz mono）
- ScreenCaptureKit 配置：`capturesAudio=true`, `excludesCurrentProcessAudio=true`（排除应用自身音频）, `sampleRate=48000`, `channelCount=1`
- 系统音频从 48kHz 重采样到 16kHz
- 两路音频长度对齐（短的零填充到长的长度）
- RMS 归一化：目标 RMS = 0.05，epsilon = 1e-8
- 50/50 混合：`mixed = 0.5 * sys_normalized + 0.5 * mic_normalized`

**分段策略（VAD）**：
- 使用 Silero VAD（speech-swift 自带）进行语音活动检测
- 最少积累 20 秒后开始寻找静音切割点
- 静音阈值：0.8 秒无语音则切割
- 强制切割：单段最长 40 秒
- 段与段之间 0.5 秒重叠，防止边界丢字
- 切割点选择逻辑：对积累的音频调用 VAD 获取所有语音段，在相邻语音段之间寻找 ≥ 0.8 秒的静音间隙，**切点在间隙中间位置**。如果完全没有语音，切在末尾
- 每个段落切割后**立即转写**（不等到会议结束），追加写入 Markdown 文件

**输出格式**：
```
# 会议纪要
日期：2026-03-29
时间：14:00 - 15:30
时长：1小时30分钟

---

**[00:00:05]** 第一段转写文字...
**[00:00:28]** 第二段转写文字...
```

**触发方式**：
- GUI 中的开始/停止按钮
- 双 Command 键快捷键（两个 Command 键在 300ms 内先后按下）

**与语音输入的互斥规则**：
- 双 Command 触发会议切换时，如果正在进行语音录音，语音录音立即取消（不识别、不输出）
- 会议录制期间，单键触发（如右 Command）的语音输入被屏蔽，不响应
- 会议停止后，语音输入恢复正常

**保存路径**：
- 默认：`~/Documents/VoiceAura/`（保持与 Python 版兼容）
- 可通过设置修改

**会议纪要完整数据流**：
```
用户点击"开始会议"按钮（或双 Command 快捷键）
  → MeetingService 启动
  → 同时开启两路音频采集：
      路线A: ScreenCaptureKit → 系统音频 (48kHz) → 重采样至 16kHz
      路线B: AVAudioEngine → 麦克风音频 (16kHz)
  → 两路音频 RMS 归一化（目标 0.05）→ 50/50 混合
  → 混合音频持续写入 buffer

  → VAD + 转写循环（可选两种实现）：

  方案 A（手动 VAD，与 Python 版逻辑一致）：
      buffer 积累 ≥ 20 秒后，调用 vad.detectSpeech() 获取语音段
      在语音段间隙 ≥ 0.8 秒处切割，切点在间隙中间
      单段达到 40 秒强制切割
      段与段之间保留 0.5 秒重叠
      每段切割后调用 asr.transcribe(segment) → 追加到 Markdown

  方案 B（使用 speech-swift 内置 StreamingASR，更简洁）：
      let config = StreamingASRConfig(maxSegmentDuration: 40.0, language: "Chinese")
      for try await segment in streamingASR.transcribeStream(audio:config:) {
          appendToMarkdown(segment.text, at: segment.startTime)
      }

  推荐方案 B，因为 StreamingASR 已经内置了 VAD + 分段 + 转写的完整流水线。
  如果需要精确控制 VAD 参数（与 Python 版完全一致），使用方案 A。

用户点击"停止会议"（或再次双 Command）
  → 处理 buffer 中剩余音频
  → 写入 Markdown 文件头（日期、时间范围、总时长）
  → 关闭文件
```

**会议录制时的 UI 变化**：
- "开始会议"按钮变为红色"停止会议"按钮
- 会议 Tab 显示当前录制时长（实时更新）
- 如果语音输入服务未启动，开始会议时自动启动

### 2.3 录音浮窗（Overlay）

录音时在屏幕顶部居中显示一个小型浮窗，告知用户正在录音。

**外观**：
- 位置：屏幕顶部居中，距顶部约 12px
- 尺寸：约 60x36px，圆角 18px
- 背景：毛玻璃效果（vibrancy）
- 内容：5 根竖向动画条（波形效果），用正弦波驱动高度变化
- 颜色：紫蓝色调（#7D5EA8）

**行为**：
- 录音开始时淡入，波形开始动画
- 录音停止时波形缩小到最低，淡出
- 始终置顶（floating panel），不影响其他窗口操作
- 不可点击、不可获取焦点

---

## 三、设置界面

### 3.1 整体布局

采用 **左侧导航栏 + 右侧内容面板** 的两栏式布局（参考 Type4Me）。

- 左侧：固定宽度的导航列表，列出各设置分类
- 右侧：选中分类对应的设置内容
- 最小窗口尺寸：800x600

### 3.2 视觉风格

**保留 Voice Aura 的 Glassmorphism 风格**，以下是从 Python 版提取的完整设计参数。

> 注意：布局结构参考 Type4Me，但颜色和视觉风格必须保留 Voice Aura 的既有设计。

#### 色板（Color Palette）

**背景色**：
| 用途 | 色值 |
|------|------|
| 主窗口背景 | `#E8EEF8` |
| 面板/容器背景 | `#F2F6FC` |
| 卡片背景 | `#FFFFFF` |
| 输入框背景 | `#F5F8FE` |

**文字色**：
| 用途 | 色值 |
|------|------|
| 主要文字 | `#2C3E6B` |
| 次要文字 | `#5A7098` |
| 提示/弱文字 | `#8AA0BE` |
| 按钮文字 | `#3A4E7A` |

**按钮色**：
| 用途 | 默认 | 悬停 |
|------|------|------|
| 主色调按钮 | `#7B8CF5` | `#6270E0` |
| 绿色按钮（启动） | `#A8E6CF` | `#80D8B8` |
| 红色按钮（停止） | `#FFB3C1` | `#FF8FA3` |
| 紫色按钮（保存） | `#E0D4F5` | `#D4C4F0` |

**状态指示色**：
| 状态 | 色值 |
|------|------|
| 运行中/就绪 | `#4ECDC4`（青绿） |
| 错误/停止 | `#FF6B8A`（红） |
| 加载中 | `#C89828`（琥珀） |

**边框与输入框**：
| 用途 | 色值 |
|------|------|
| 卡片/通用边框 | `#C8D8EA` |
| 输入框边框 | `#C0D0E4` |
| 输入框聚焦边框 | `#7B8CF5` |
| 列表选中背景 | `#D8E4F8` |

**进度条**：背景 `#C8D8EA`，填充 `#4ECDC4`，圆角 5px，高度 10px

**开关（Toggle）**：44×24px，关闭态背景 `#C8D8EA`，开启态 `#4ECDC4`，滑块白色 9px 半径

#### 动画背景参数

> 注意：Python 版的动画循环实际为空操作（`pass`），球体/气泡是**静态定位**的。Swift 版可选择：(a) 保持静态以节省性能；(b) 实现真正动画则建议用 `CADisplayLink` + Metal/CALayer，避免 SwiftUI `TimelineView` 性能问题。以下参数适用于两种方案。

**发光球体（Orbs）**：5 个
- 半径范围：140-260px
- 运动速度：0.015-0.04
- 发光层数：4 层，缩放 `1.0 + t * 1.8`
- 与背景混合比：85%
- 帧间隔：80ms
- 颜色池（RGB）：
  `(100,140,255)` `(160,100,255)` `(80,200,220)` `(255,120,180)` `(120,200,255)` `(180,130,255)` `(100,220,200)` `(255,150,200)`

**玻璃气泡（Bubbles）**：12 个
- 半径范围：20-55px
- 运动速度：0.04-0.12
- 发光层数：3 层，缩放 `1.0 + t * 0.6`
- 与背景混合比：80%
- 高光尺寸：0.35×半径宽 × 0.4×半径高偏移
- 额外颜色：`(140,180,255)` `(200,140,255)`

#### 录音浮窗参数

- 尺寸：60×36px，圆角 18px
- 背景：HUD 毛玻璃材质（`NSVisualEffectView`, `HUDWindow` material, `BehindWindow` blending）
- 窗口层级：`NSFloatingWindowLevel`，不可点击
- 位置：屏幕顶部居中，距可见区域顶部 12px
- 波形条：5 根，宽 4px，间距 3px，最大高度 20px，最小 4px
- 波形颜色：`RGBA(0.49, 0.37, 0.65, alpha)`，alpha 范围 0.6-1.0（按高度比）
- 动画间隔：60ms，相位 `time * 4.0 + bar_index * 0.9`，正弦波驱动

#### 排版与间距

| 参数 | 值 |
|------|------|
| 字体 | Helvetica（SwiftUI 中用系统字体即可） |
| 标题字号 | 22pt |
| 正文字号 | 12pt |
| 按钮字号 | 13pt |
| 提示字号 | 10pt |
| 卡片圆角 | 12px |
| 按钮圆角 | 11px |
| 窗口初始尺寸 | 960×1240（或屏幕高度-100） |
| 窗口最小尺寸 | 800×600 |
| 按钮按下效果 | 下移 2px |

### 3.3 导航栏样式

```
侧栏宽度: 180pt
侧栏背景: #F2F6FC (bg_panel)
选中项背景: #D8E4F8 (list_sel)
选中项文字: #7B8CF5 (accent)
未选中文字: #2C3E6B (text)
项目内边距: 12pt 垂直, 16pt 水平
项目字号: 13pt
侧栏与内容分割线: 1pt #C8D8EA (border)
```

### 3.4 导航分类

**四个 Tab**：

#### Tab 1：通用（General）
- 服务状态显示（运行中/加载中/已停止）+ 启动/停止按钮
- 模型下载进度条（下载时显示）
- 触发键选择（下拉框）→ **需要重启服务**才能生效
- 模型选择（0.6B 极速 / 1.7B 精确）→ **需要重启服务**才能生效（需重新加载模型）
- 功能开关（即时生效，无需重启）：
  - 去除语气词（默认开启）
  - 空格重定位（默认开启）

> 触发键或模型变更时，提示用户"设置已保存，需要重启服务生效"，并提供"立即重启"按钮。

#### Tab 2：词汇（Vocabulary）
- **热词管理**：
  - 标签式展示（标签背景 `#F2F6FC`，边框 1pt `#C8D8EA`，圆角 8pt），点击 x 删除
  - 输入框添加新热词（回车确认）
  - 说明文字："传递给识别模型，帮助识别专有名词"
- **替换规则**：
  - 表格式展示：错误词 → 正确词
  - 支持添加、编辑、删除
  - 说明文字："识别后自动替换的文字"
- **变更后需重启服务**：热词和替换规则在服务启动时加载，修改后显示"重启服务生效"提示（与 Tab 1 触发键/模型变更相同机制）

#### Tab 3：会议（Meeting）
- 保存路径显示 + 文件夹选择按钮
- 会议开始/停止按钮
- 录制时长显示：格式 `HH:MM:SS`，字号 18pt 等宽字体，颜色 `#C89828`（琥珀），录制中实时更新
- 双 Command 快捷键说明
- 如果语音服务未启动，点击"开始会议"时提示"请先启动语音服务加载模型"

#### Tab 4：关于（About）
- 应用名称和版本号
- 权限状态显示（辅助功能、麦克风、屏幕录制）
- 每项权限的状态指示 + 跳转系统设置按钮

### 3.5 首次使用引导（Onboarding）

首次启动时弹出引导对话框（500×560pt，居中，模态）：
1. 辅助功能权限（键盘监听和文字输入所需）
2. 麦克风权限（语音录制所需）
3. 屏幕录制权限（会议纪要的系统音频采集所需）

每项权限实时显示授权状态（每 2 秒轮询刷新），提供跳转到系统设置的按钮。

**触发条件**：Onboarding 仅在 `isFreshInstall() == true` **且** `onboardingDone == false` 时显示。已有配置文件的用户即使 `onboardingDone` 字段缺失，也不会触发 Onboarding（因为 `isFreshInstall()` 返回 false）。

**按钮行为**：
- "开始使用"：设置 `onboardingDone = true`，关闭对话框
- "稍后再说"：关闭对话框但**不**设置 `onboardingDone`，下次启动仍会显示
- 窗口关闭按钮（红色 X）：与"稍后再说"行为相同

---

## 四、系统集成

### 4.1 权限需求
- **辅助功能（Accessibility）**：用于全局键盘监听和模拟按键粘贴
- **麦克风（Microphone）**：用于语音录制
- **屏幕录制（Screen Recording）**：用于会议纪要的系统音频采集

### 4.2 键盘监听
- 使用 macOS CGEventTap 实现全局键盘事件监听
- 事件类型：监听 `kCGEventFlagsChanged`（修饰键）+ `kCGEventKeyDown` + `kCGEventKeyUp`
- CGEventTap 配置：`kCGSessionEventTap`, `kCGHeadInsertEventTap`, `kCGEventTapOptionDefault`

**macOS 虚拟键码**：
| 键名 | 键码 | 标志位掩码 |
|------|------|-----------|
| cmd_r | 0x36 | kCGEventFlagMaskCommand |
| cmd_l | 0x37 | kCGEventFlagMaskCommand |
| alt_r | 0x3D | kCGEventFlagMaskAlternate |
| alt_l | 0x3A | kCGEventFlagMaskAlternate |
| ctrl | 0x3B | kCGEventFlagMaskControl |
| shift | 0x38 | kCGEventFlagMaskShift |
| space | 0x31 | — |

**关键设计原则**：
- CGEventTap 的回调必须快速返回，否则 macOS 会禁用该事件监听
- 因此：回调中只设置标志位（如 Event/Bool），on_release 和 on_meeting_toggle 等重量级操作在**独立后台线程/Task** 中执行
- 具体机制：回调设置 flag → RunLoop 迭代检测到 flag → 派发新线程执行回调。在 Swift 中可用 `Task.detached {}` 或 `DispatchQueue.global().async {}`
- 双 Command 检测逻辑：记录第一个 Command 键按下的时间戳，当另一个 Command 键也按下时，如果时间差 < 300ms 则触发会议切换
- 会议切换触发时，如果正在进行语音录音，**立即取消**（不触发 on_release、不做识别、不输出文字），同时隐藏录音浮窗、清空音频 buffer

**meetingActive 标志**：
- KeyboardListener 维护一个 `meetingActive: Bool` 属性
- 当 `meetingActive == true` 时，单键触发（按下/松开触发键）的 on_press 和 on_release 回调被完全跳过，修饰键事件仍正常传递给系统（用户可以正常使用 Command 做其他快捷键操作）
- GUI 在开始会议前设置 `meetingActive = true`，停止会议后设置 `meetingActive = false`

### 4.3 文字输入（TextInjector）

Voice-Aura（Python 版）通过 `subprocess.Popen(["osascript", ...])` 调用 AppleScript 模拟 Cmd+V，多了一层进程开销和失败点。Swift 版直接用 CGEvent API，更快更可靠。

**完整流程**：
```
1. 保存当前剪贴板
   NSPasteboard.general 遍历所有 pasteboardItems
   对每个 item 的每个 type，用 data(forType:) 读出 Data，存入内存

2. 写入识别文字
   NSPasteboard.general.clearContents()
   NSPasteboard.general.setString(text, forType: .string)

3. 模拟 Cmd+V（CGEvent 直接发送，无 osascript）
   let source = CGEventSource(stateID: .hidSystemState)
   // keyDown: virtualKey = 0x09 (V), flags = .maskCommand
   // keyUp:   virtualKey = 0x09 (V), flags = .maskCommand
   // post(tap: .cghidEventTap)

4. 等待粘贴完成
   usleep(200_000)  // 200ms

5. 恢复原剪贴板
   NSPasteboard.general.clearContents()
   用保存的数据重建所有 NSPasteboardItem 并 writeObjects

6. 粘贴失败时的降级
   如果 CGEvent 创建失败，发送 macOS 通知告知用户"文字已复制到剪贴板，请手动 Cmd+V"
   此时不恢复剪贴板（保留识别文字供手动粘贴）
```

**剪贴板竞态防护**：在步骤 5 恢复前，检查 `NSPasteboard.general.changeCount`。如果 changeCount 与步骤 2 写入后不同（说明用户或其他程序在此期间修改了剪贴板），则跳过恢复，保留用户的新内容。

**对比 Python 版的改进**：
| | Python 版 (Voice-Aura) | Swift 版 (Voice Brother) |
|---|---|---|
| 粘贴模拟 | osascript 子进程调 AppleScript | CGEvent 直接发键盘事件 |
| 延迟 | ~100-200ms（启动 osascript 进程） | <1ms（内存中构造事件） |
| 失败点 | osascript 可能超时/返回非零 | CGEvent 几乎不会失败 |
| 剪贴板操作 | NSPasteboard (PyObjC) | NSPasteboard (原生 Swift) |

### 4.4 录音浮窗必须用 NSPanel

SwiftUI Window 无法实现以下特性，因此录音浮窗**必须用 AppKit NSPanel**：
- `NSFloatingWindowLevel`（浮于所有窗口之上，包括全屏应用）
- `setIgnoresMouseEvents(true)`（点击穿透）
- `NSWindowStyleMask.nonactivatingPanel`（不抢焦点）
- `canJoinAllSpaces | stationary | fullScreenAuxiliary`（所有桌面可见）

波形动画本身可以是 SwiftUI View，通过 `NSHostingView` 嵌入 NSPanel。

### 4.5 应用行为
- `LSUIElement = false`（显示 Dock 图标）
- 窗口关闭时隐藏到后台（不退出）：`applicationShouldTerminateAfterLastWindowClosed` 返回 `false`
- Cmd+Q 完全退出：在 `applicationWillTerminate` 中清理所有 Service
- 点击 Dock 图标恢复窗口：实现 `applicationShouldHandleReopen(_:hasVisibleWindows:)` 重新显示主窗口

### 4.6 构建、签名与分发

**不能使用 App Sandbox**——CGEventTap 与沙盒不兼容。

**Info.plist 必需条目**：
- `NSMicrophoneUsageDescription`: "Voice Brother 需要麦克风权限来录制语音"
- `NSScreenCaptureUsageDescription`: "Voice Brother 需要屏幕录制权限来采集系统音频（会议纪要功能）"

**签名与公证**：
- 必须使用 Developer ID 证书签名（否则 CGEventTap 在 macOS 13+ 上被拒绝）
- 必须启用 Hardened Runtime
- 分发前需要通过 Apple 公证（notarization）

**最低部署目标**：macOS 14.0（由 speech-swift 要求决定）

---

## 五、应用状态机

整个应用有一个核心状态，决定了 UI 显示和用户可执行的操作。

### 5.1 服务状态（VoiceService）

```
[未启动] ──用户点击"启动"──→ [检查当前模型]
   ↑                              │
   │                    已缓存？──是──→ [加载模型] ──成功──→ [就绪]
   │                         │                   │        │
   │                         否                  失败     后台下载另一个模型
   │                         ↓                   ↓       （不阻塞使用）
   │                    [下载模型] ──成功──→ [加载模型]   [错误]
   │                         │                             │
   │                        失败 ─────────────────────→ [错误]
   │                                                       │
   └──────────────────用户点击"停止"←──────────────────────┘

[就绪] 状态下：
  按下触发键 → [录音中]
  松开触发键 → [识别中] → 识别完成 → [就绪]
  识别失败 → 打印错误，回到 [就绪]（不崩溃）
```

### 5.2 会议状态（MeetingService）

```
[空闲] ──开始会议──→ [录制中] ──停止会议──→ [处理剩余] ──完成──→ [空闲]
                       │
                     错误 → 通知用户，回到 [空闲]
```

### 5.3 UI 状态映射

| 服务状态 | 启动按钮 | 停止按钮 | 进度条 | 状态文字 | 状态颜色 |
|---------|---------|---------|--------|---------|---------|
| 未启动 | 可点击 | 灰色 | 隐藏 | "已停止" | 灰色 |
| 下载模型 | 灰色 | 可点击 | 显示+百分比 | "下载中 1.2GB/2.5GB" | 蓝色 |
| 加载模型 | 灰色 | 可点击 | 无限滚动 | "加载模型到内存中..." | 蓝色 |
| 就绪 | 灰色 | 可点击 | 隐藏 | "运行中" | 绿色 |
| 录音中 | 灰色 | 灰色 | 隐藏 | "录音中..." | 橙色 |
| 识别中 | 灰色 | 灰色 | 隐藏 | "识别中..." | 橙色 |
| 错误 | 可点击 | 灰色 | 隐藏 | 错误信息 | 红色 |

---

## 六、错误处理

每种错误场景都必须有明确的用户反馈，不允许静默失败。

### 6.1 启动阶段错误

| 错误场景 | 用户看到的反馈 | 恢复方式 |
|---------|--------------|---------|
| 模型下载失败（网络问题） | 状态显示"下载失败: [错误信息]"，变红 | 用户重新点击"启动" |
| 模型加载失败（内存不足） | 状态显示"加载失败: [错误信息]" | 建议切换到 0.6B 模型 |
| 辅助功能权限未授权 | 状态显示"需要辅助功能权限" + 跳转按钮 | 用户授权后重新启动 |
| 麦克风权限未授权 | 状态显示"需要麦克风权限" + 跳转按钮 | 用户授权后重新启动 |

### 6.2 运行阶段错误

| 错误场景 | 处理方式 |
|---------|---------|
| 单次识别失败 | 打印日志，回到就绪状态，不打断用户工作流 |
| 音频流中断 | 尝试重新打开，失败则通知用户 |
| 粘贴失败（Cmd+V 超时） | 发送 macOS 通知"文字已复制到剪贴板，请手动粘贴"，不恢复剪贴板（让用户手动粘贴） |
| 会议录制中系统音频采集失败 | 仅用麦克风继续录制，通知用户"系统音频采集失败，仅录制麦克风" |

---

## 七、架构分层与模块边界

### 7.1 核心原则

**前端和后端通过"共享层"解耦**。前端不依赖后端的具体实现，只依赖共享层定义的协议和数据类型。这意味着：
- 做前端时，可以用 Mock 实现替代真实后端，不需要等后端完成
- 做后端时，不需要关心 UI 长什么样，只需要实现协议
- 两边可以由不同的 AI 或不同的会话并行开发

### 7.2 三层结构与目录

```
VoiceBrother/
├── Shared/                      ← 共享层：数据类型 + 协议定义
│   ├── Types.swift              ← 枚举、结构体（两边都用）
│   ├── AppConfig.swift          ← 配置模型
│   └── Protocols.swift          ← 所有服务的协议接口
│
├── Backend/                     ← 后端：实现协议
│   ├── Voice/                   ← 语音输入领域
│   │   ├── VoiceService.swift       ← 语音输入生命周期
│   │   ├── KeyboardListener.swift   ← CGEventTap 键盘监听
│   │   ├── TextInjector.swift       ← 剪贴板保护 + CGEvent 粘贴
│   │   └── TextProcessor.swift      ← 语气词过滤 + 替换规则
│   ├── Meeting/                 ← 会议纪要领域
│   │   └── MeetingService.swift     ← 会议纪要生命周期
│   └── Services/                ← 跨领域基础服务
│       ├── ConfigManager.swift      ← 配置持久化
│       ├── PermissionManager.swift  ← 权限检测与引导
│       └── HistoryManager.swift     ← 转写历史存储（SQLite actor）
│
├── Frontend/                    ← 前端：SwiftUI 视图
│   ├── MainWindow.swift         ← 左侧导航 + 右侧内容
│   ├── Tabs/
│   │   ├── GeneralTab.swift     ← 通用设置
│   │   ├── VocabularyTab.swift  ← 热词 + 替换规则
│   │   ├── HistoryTab.swift     ← 转写历史
│   │   ├── MeetingTab.swift     ← 会议设置
│   │   └── AboutTab.swift       ← 关于页
│   ├── Components/
│   │   ├── ColorExtension.swift          ← 颜色扩展 + glassCard 修饰符
│   │   ├── GlassmorphismBackground.swift ← 动画背景
│   │   ├── RecordingOverlayPanel.swift   ← 录音浮窗窗口（NSPanel，非纯 SwiftUI）
│   │   └── RecordingWaveformView.swift   ← 波形动画（SwiftUI，嵌入 NSPanel）
│   └── OnboardingView.swift     ← 首次引导
│
└── VoiceBrotherApp.swift         ← 应用入口：创建后端实例，注入到前端
```

### 7.3 共享层：数据类型

前后端都依赖这些类型，它们不包含任何业务逻辑，只是数据定义。

**ServiceState**（语音服务状态枚举）：
```
enum ServiceState {
    case stopped           // 未启动
    case downloading       // 下载模型中
    case loading           // 加载模型中
    case ready             // 就绪，等待触发
    case recording         // 录音中
    case transcribing      // 识别中
    case error(String)     // 错误，附带信息
}
```

**MeetingState**（会议状态枚举）：
```
enum MeetingState {
    case idle              // 空闲
    case recording         // 录制中
    case finishing         // 处理剩余音频
    case error(String)     // 错误
}
```

**DownloadProgress**（下载进度）：
```
struct DownloadProgress {
    let downloaded: Int64  // 已下载字节
    let total: Int64       // 总字节（0 表示未知）
    let description: String // "1.2 GB / 2.5 GB"
}
```

**PermissionStatus**（权限状态）：
```
struct PermissionStatus {
    let accessibility: Bool
    let microphone: Bool
    let screenRecording: Bool
}
```

**AppConfig**（配置模型，详见第八章完整字段列表）

### 7.4 共享层：协议定义

以下协议是前后端之间的"合同"。前端只看到协议，不看到具体实现。

**VoiceServiceProtocol**：
```
protocol VoiceServiceProtocol: ObservableObject {
    // ── 状态（前端观察）──
    var state: ServiceState { get }         // @Published
    var downloadProgress: DownloadProgress? { get }  // @Published

    // ── 操作（前端调用）──
    func start()
    func stop()

    // ── 设置（前端修改，即时生效）──
    var removeFillers: Bool { get set }
    var spaceReposition: Bool { get set }
}
```

**MeetingServiceProtocol**：
```
protocol MeetingServiceProtocol: ObservableObject {
    // ── 状态 ──
    var state: MeetingState { get }         // @Published
    var elapsedSeconds: Int { get }         // @Published, 录制时长

    // ── 操作 ──
    func start()
    func stop()
    func toggle()

    // ── 设置 ──
    var savePath: String { get set }
}
```

**ConfigManagerProtocol**：
```
protocol ConfigManagerProtocol: ObservableObject {
    // ── 所有配置项（前端双向绑定）──
    var triggerKey: String { get set }      // @Published
    var modelName: String { get set }       // @Published
    var hotwords: [String] { get set }      // @Published
    var replacements: [(String, String)] { get set }  // @Published
    var removeFillers: Bool { get set }     // @Published
    var spaceReposition: Bool { get set }   // @Published
    var meetingSavePath: String { get set }  // @Published
    var onboardingDone: Bool { get set }    // @Published

    // ── 操作 ──
    func save()
    func isFreshInstall() -> Bool
}
```

**PermissionManagerProtocol**：
```
protocol PermissionManagerProtocol: ObservableObject {
    // ── 状态 ──
    var status: PermissionStatus { get }    // @Published

    // ── 操作 ──
    func recheckAll()
    func openAccessibilitySettings()
    func openMicrophoneSettings()
    func openScreenRecordingSettings()
}
```

### 7.5 前后端通信规则

| 规则 | 说明 |
|------|------|
| **前端 → 后端** | 调用协议方法（如 `voiceService.start()`）或修改协议属性（如 `config.triggerKey = "ctrl"`） |
| **后端 → 前端** | 通过 `@Published` 属性变更自动触发 UI 刷新，后端在主线程（`@MainActor`）更新状态 |
| **前端之间** | 通过 `@EnvironmentObject` 共享同一个服务实例，无需消息传递 |
| **后端之间** | VoiceService 和 MeetingService **各自创建独立的 ASR 模型实例**（speech-swift 不是线程安全的） |

**模型实例策略**：
- `Qwen3ASRModel` 不是线程安全的，不能在多线程间共享同一个实例
- VoiceService 启动时创建自己的模型实例（用于语音输入转写）
- MeetingService 启动时创建自己的模型实例（用于会议段落转写）
- 两个实例使用同一个 modelId，加载同一份缓存文件（`~/Library/Caches/qwen3-speech/`），不会重复下载
- 内存代价：0.6B 模型约 400MB × 2 = 800MB；1.7B 模型约 2.5GB × 2 = 5GB。如果内存紧张，可在会议开始时创建、会议结束时释放（`model.unload()`）
- 如果 MeetingService 启动时模型尚未下载，应提示用户"请先启动语音服务下载模型"

### 7.6 依赖注入（应用入口）

`VoiceBrotherApp.swift`（应用入口）是唯一知道所有具体实现类的地方：
```
创建 ConfigManager（具体类）
创建 PermissionManager（具体类）
创建 VoiceService（具体类，注入 ConfigManager）
创建 MeetingService（具体类，注入 ConfigManager，独立创建自己的模型实例）
将所有服务作为 @EnvironmentObject 注入到 MainWindow
```

前端的所有 View 通过 `@EnvironmentObject` 获取服务，不需要知道它是真实实现还是 Mock。

### 7.7 Mock 开发（前端独立开发时使用）

开发前端时，可以创建 Mock 实现：
```
MockVoiceService: VoiceServiceProtocol
  - state 固定返回 .ready
  - start()/stop() 切换状态
  - 不做任何实际录音/识别

MockConfigManager: ConfigManagerProtocol
  - 所有属性用内存变量存储
  - save() 不做任何持久化
```

这样前端开发时不需要真实的 ASR 模型、不需要麦克风权限，只需要一个假的服务实例就能看到完整 UI 并测试交互。

### 7.8 后端模块详细职责

| 模块 | 输入 | 输出 | 内部依赖 |
|------|------|------|---------|
| **VoiceService** | 触发键事件、音频流 | ServiceState, 识别结果（自动注入到光标） | KeyboardListener, TextInjector, TextProcessor, ConfigManager |
| **MeetingService** | 开始/停止指令 | MeetingState, Markdown 文件 | 独立 ASR 模型实例, TextProcessor, ConfigManager |
| **KeyboardListener** | CGEventTap 事件 | 回调: onPress, onRelease, onReposition, onMeetingToggle; 属性: meetingActive | 无 |
| **ConfigManager** | 用户设置修改 | 持久化到磁盘，通知观察者 | 无 |
| **PermissionManager** | 系统 API 查询 | PermissionStatus | 无 |
| **TextInjector** | 待输入的文字 String | 文字出现在光标位置 | 无（独立工具类） |
| **TextProcessor** | 原始识别文字 + 配置 | 处理后的文字 | 无（纯函数，无状态） |

### 7.9 前端模块详细职责

| 模块 | 观察哪些状态 | 调用哪些操作 |
|------|------------|------------|
| **MainWindow** | ConfigManager.onboardingDone | 无（纯容器） |
| **GeneralTab** | VoiceService.state, .downloadProgress, ConfigManager 配置项 | voiceService.start/stop(), config 属性修改 |
| **VocabularyTab** | ConfigManager.hotwords, .replacements | config.hotwords 增删, config.replacements 增删改 |
| **MeetingTab** | MeetingService.state, .elapsedSeconds, ConfigManager.meetingSavePath | meetingService.start/stop/toggle(), config.meetingSavePath |
| **AboutTab** | PermissionManager.status | permissionManager.recheckAll(), .openXxxSettings() |
| **OnboardingView** | PermissionManager.status | permissionManager.openXxxSettings(), config.onboardingDone = true |
| **RecordingOverlayPanel** | VoiceService.state（.recording 时显示） | 无（纯展示，NSPanel + NSHostingView 包裹 SwiftUI 波形） |

---

## 八、配置持久化

所有用户设置需持久化存储，应用重启后保持。

**存储方式**：UserDefaults 或 `~/Library/Application Support/VoiceBrother/config.json`（不与 Python 版共用文件）。

**加载逻辑**：先加载默认配置，再加载用户配置覆盖。用户配置中缺失的 key 从默认配置补齐（向前兼容，新版本增加配置项时旧配置不会报错）。

**从 Python 版迁移配置**：首次启动时，如果检测到 `~/.voice_config.json` 存在：
1. 读取并导入热词、替换规则、触发键、会议保存路径等设置
2. 替换规则从 dict `{key: value}` 转换为有序数组 `[{from, to}]`（按原 JSON 顺序）
3. 导入后不修改原文件（Python 版可继续使用）
4. 仅执行一次，导入后标记 `migrated_from_voice_aura = true`

**需要持久化的配置项**：
- trigger_key：触发键（默认 "cmd_r"）
- model：模型名称（默认 "Qwen/Qwen3-ASR-1.7B" 精确版）
- hotwords：热词列表
- replacements：替换规则字典
- remove_fillers：是否去除语气词（默认 true）
- space_reposition：是否启用空格重定位（默认 true）
- meeting_save_path：会议纪要保存路径（默认 ~/Documents/VoiceAura/）
- onboarding_done：是否已完成首次引导

**默认热词**：Claude Code, OpenRouter, n8n, 智谱, GLM, Sonnet, Opus

**默认替换规则**（有序数组，按此顺序应用）：
| 错误 | 正确 |
|------|------|
| cloud code | Claude Code |
| cloud cold | Claude Code |
| 克劳德 | Claude |
| n八n | n8n |
| N八n | n8n |
| 质朴 | 智谱 |
| G L M | GLM |
| open router | OpenRouter |
| openrouter | OpenRouter |
| code x | CodeX |
| sonnet | Sonnet |
| opus | Opus |

> **重要**：替换规则必须存储为**有序数组** `[{from: "...", to: "..."}, ...]`，不能用字典/Dictionary。Python dict 恰好保序（3.7+），但 Swift Dictionary 是无序的。应用替换时按数组顺序逐条执行。

---

## 九、技术方向

### 选型决策

| 层面 | 选择 | 原因 |
|------|------|------|
| 语言 | Swift | macOS 原生，无需打包 Python 环境 |
| UI 框架 | SwiftUI | 原生控件，适配系统主题，代码简洁 |
| ASR 引擎 | Qwen3-ASR via speech-swift (MLX) | 中文识别质量最优，Apple Silicon 加速 |
| VAD | Silero VAD (speech-swift 自带) | 与 ASR 库同生态，无需额外依赖 |
| 构建 | Swift Package Manager | speech-swift 以 SPM 包形式引入 |
| 音频 | AVAudioEngine / ScreenCaptureKit | 系统原生音频 API |
| 键盘 | CGEventTap | 低级别全局键盘监听 |

### speech-swift 库信息

- 仓库：`https://github.com/soniqo/speech-swift`（原名 qwen3-asr-swift）
- 包名：`Qwen3Speech`
- SPM 引入：`https://github.com/soniqo/speech-swift`
- 需要的 library target：`Qwen3ASR`（语音识别）、`SpeechVAD`（语音活动检测）、`AudioCommon`（音频工具）
- 依赖：`mlx-swift` >= 0.30.0、`swift-transformers`（HF Hub 下载）
- 要求：macOS 14+，Apple Silicon，Xcode 15+，Swift 5.9+
- 许可：Apache 2.0
- 状态：487 stars，活跃开发中（2026-02 创建），暂无已知生产应用
- MLX vs PyTorch 质量：**无损失**，67% 样本完全一致，MLX 速度快 3-4 倍

### 验证结果（2026-03-29 从源码确认）

所有关键验证项已通过，方案可行性已确认：

| # | 验证项 | 结果 | 具体 API |
|---|--------|------|---------|
| 1 | context 参数（热词） | ✅ 通过 | `model.transcribe(audio:sampleRate:language:maxTokens:context:)` — context 作为 system prompt 注入 |
| 2 | VAD 段落检测 | ✅ 通过 | `vad.detectSpeech(audio:sampleRate:config:) -> [SpeechSegment]`，每个 segment 有 `.startTime` / `.endTime`（秒） |
| 3 | Float32 数组输入 | ✅ 通过 | `audio: [Float]`，直接传内存 PCM 数据 |
| 4 | MLX 构建 | ✅ 通过 | SPM 标准构建，依赖 mlx-swift >= 0.30.0 |

**模型缓存位置**：`~/Library/Caches/qwen3-speech/`（可通过 `$QWEN3_CACHE_DIR` 环境变量覆盖）

**speech-swift 关键 API 参考**：

```swift
// ASR 模型加载
let asr = try await Qwen3ASRModel.fromPretrained(
    modelId: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit",  // 或 aufklarer/Qwen3-ASR-1.7B-MLX-8bit
    progressHandler: { progress, status in ... }
)

// 语音转写（带热词 context）
let text = asr.transcribe(
    audio: floatSamples,     // [Float] PCM 16kHz
    sampleRate: 16000,
    language: "Chinese",
    context: "Claude Code n8n 智谱"  // 热词拼接
)

// VAD 段落检测
let vad = try await SileroVADModel.fromPretrained(engine: .coreml)
let segments = vad.detectSpeech(audio: floatSamples, sampleRate: 16000)
// segments: [SpeechSegment(startTime: 0.5, endTime: 3.2), ...]

// StreamingASR（会议纪要可直接使用）
let streaming = try await StreamingASR.fromPretrained(...)
let config = StreamingASRConfig(
    maxSegmentDuration: 40.0,
    language: "Chinese",
    context: nil  // 会议不传热词
)
for try await segment in streaming.transcribeStream(audio: samples, config: config) {
    appendToMarkdown(segment.text, at: segment.startTime)
}

// 模型内存管理
asr.unload()  // 释放模型内存
asr.isLoaded  // 检查是否已加载
asr.memoryFootprint  // 内存占用字节数
```

**HuggingFace 模型 ID**：
| 模型 | ID | 大小 |
|------|-----|------|
| 0.6B 4-bit（极速） | `aufklarer/Qwen3-ASR-0.6B-MLX-4bit` | ~400MB |
| 1.7B 8-bit（精确） | `aufklarer/Qwen3-ASR-1.7B-MLX-8bit` | ~2.5GB |
| Silero VAD (CoreML) | `aufklarer/Silero-VAD-v5-CoreML` | 小 |
| Silero VAD (MLX) | `aufklarer/Silero-VAD-v5-MLX` | 小 |

**线程安全注意**：`Qwen3ASRModel` 和 `SileroVADModel` 都**不是线程安全的**。并发使用必须创建独立实例。

### 为什么不选 SherpaOnnx（已验证排除）

| 问题 | 详情 |
|------|------|
| **热词不支持 Qwen3-ASR** | 源码 `exit(-1)`: "Only transducer models support contextual biasing" — Qwen3-ASR 是 encoder-decoder 架构，不是 transducer |
| **仅离线模式** | v1.12.34 只加了 offline Qwen3-ASR，无流式 |
| **CPU only** | ONNX Runtime 在 macOS 不走 Metal GPU，比 MLX 慢 3-5 倍 |
| **无质量对比** | ONNX int8 转换无公开精度基准 |

### 不做的事情

- **不做 LLM 后处理**：不接入大模型做文字优化/翻译等。原因：会增加延迟，当前场景不需要
- **不做 Toggle 录音模式**：只支持 hold-to-record。短录音用按住，长录音用会议纪要
- **不做录音音效**：浮窗视觉反馈已足够
- **不做录音时长显示**：面向短录音场景，不需要计时器
- **不做多语言 UI**：界面仅中文

### 从 Voice Aura 可复用的代码/逻辑

虽然 Python 和 Swift 是不同语言，但以下模块的**核心逻辑**可以直接翻译搬过来，不需要重新设计：

| Python 源文件 | 可复用内容 | 复用方式 |
|--------------|-----------|---------|
| `keyboard_listener.py` | CGEventTap 的全部逻辑：事件掩码、回调结构、键码映射、双 Command 检测、空格吞掉 | **API 层面 1:1，但回调机制需 Swift 适配**。Python 用普通函数做 callback；Swift 必须用 `@convention(c)` 闭包 + `Unmanaged<T>` 指针传递 self。线程派发从 `threading.Event` 改为 `DispatchQueue.global().async {}` |
| `voice_service.py` `remove_fillers()` | 语气词列表 + 正则清理逻辑 | **直接翻译**。Python `re.sub` → Swift `NSRegularExpression` 或 `Regex`，模式串不变 |
| `voice_service.py` `type_text()` | 剪贴板保护逻辑（保存/恢复所有 pasteboard item 类型） | **直接翻译**。Python 用 `AppKit.NSPasteboard`，Swift 用同一套 `NSPasteboard` API |
| `config.py` | 配置结构、默认值、合并逻辑 | **逻辑翻译**。JSON 结构和默认值直接搬，存储方式改为 UserDefaults 或 Swift JSON |
| `permissions.py` | 权限检测逻辑和系统设置 URL | **直接翻译**。`AXIsProcessTrusted()`、`AVCaptureDevice.authorizationStatus` 在 Swift 中有相同 API |
| `meeting_service.py` | VAD 参数常量、音频混合算法（RMS 归一化 + 50/50）、Markdown 格式和文件两遍写入逻辑 | **算法翻译**。数学计算和文件操作直接搬，音频 API 改为 AVAudioEngine/ScreenCaptureKit |
| `recording_overlay.py` | 波形动画的正弦波参数、颜色值、尺寸 | **参数搬运**。动画逻辑用 SwiftUI 重写，但数值参数（5根条、频率、颜色 #7D5EA6）直接用 |
| `main_gui.py` | Glassmorphism 动画参数（球体数量、大小、颜色、运动速度）| **参数搬运**。动画用 SwiftUI 重写，但视觉参数从 Python 版搬运以保持一致外观 |

**不可复用的部分**（必须重写）：
- Tkinter GUI → SwiftUI（完全不同的 UI 框架）
- PyTorch/qwen_asr 模型调用 → speech-swift MLX API（完全不同的推理接口）
- sounddevice 音频采集 → AVAudioEngine（不同的音频 API）
- ScreenCaptureKit 的 PyObjC 桥接 → 原生 Swift ScreenCaptureKit（更简单）

---

## 十、开发阶段

### Phase 1a - 共享层（协议冻结）
定义 Shared/ 目录下的所有类型和协议（Types.swift, Protocols.swift, AppConfig.swift）。**此阶段完成后协议接口冻结，Phase 2 可以开始。**

### Phase 1b - 后端核心
实现 VoiceService, KeyboardListener, TextInjector, TextProcessor, ConfigManager, PermissionManager。完成后应能通过命令行/单元测试验证：按键 → 录音 → 识别 → 文字输入。

### Phase 2 - 设置界面（可与 Phase 1b 并行）
左侧导航 UI + 全部设置项。使用 Mock 实现开发，不依赖真实后端。Phase 1b 完成后切换到真实实现联调。

### Phase 3 - 会议纪要（需要 Phase 1b 测试通过）
MeetingService 共享 Phase 1b 的 ASR 模型，因此必须等 Phase 1b 稳定后再开始。

### Phase 4 - 增强功能
菜单栏常驻图标、录音历史（SQLite）、开机自动启动、音频文件拖拽转写、热词批量导入导出

---

## 十一、从 Voice Aura 迁移的完整功能清单

以下是 Voice Aura 的所有功能，每一项在 Voice Brother 中都必须实现：

- [x] 定义需求（本文档）
- [ ] 按住触发键录音
- [ ] 可配置触发键（6 种选择）
- [ ] Qwen3-ASR 语音识别
- [ ] 模型选择（0.6B / 1.7B）
- [ ] 模型自动下载 + 进度显示
- [ ] 识别文字自动输入到光标位置
- [ ] 剪贴板保护（粘贴前保存，粘贴后恢复）
- [ ] 语气词过滤（可开关）
- [ ] 热词管理（增删改）
- [ ] 替换规则管理（增删改）
- [ ] 录音中空格重定位（可开关）
- [ ] 录音浮窗（毛玻璃 + 波形动画）
- [ ] 首次使用引导（权限申请）
- [ ] 辅助功能权限检测与申请
- [ ] 麦克风权限检测与申请
- [ ] 屏幕录制权限检测与申请
- [ ] 会议纪要录制（系统音频 + 麦克风）
- [ ] VAD 自动分段
- [ ] Markdown 时间戳输出
- [ ] 会议保存路径自定义
- [ ] 双 Command 键切换会议模式
- [ ] 设置持久化
- [ ] 窗口关闭隐藏 / Cmd+Q 退出
- [ ] Dock 图标

### Phase 4 新增功能（不在 Voice Aura 中）

- [ ] 左侧导航式设置界面
- [ ] 菜单栏常驻图标
- [ ] 录音历史记录
- [ ] 开机自动启动
- [ ] 音频文件拖拽转写
- [ ] 热词/替换规则批量导入导出
