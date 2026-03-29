# Voice Bubble - 项目指南

> macOS 原生语音输入应用。Swift + SwiftUI + MLX，按住说话，松开输入。

## 需求与架构

所有需求定义、数据流、状态机、API 参考均在 `PROJECT.md`。这是唯一的真相来源（single source of truth），开发前必读。

关键章节速查：
| 需要了解 | 查 PROJECT.md 章节 |
|---------|------------------|
| 核心功能与数据流 | 二、核心功能（含完整数据流图） |
| UI 设计参数（色板、间距、动画） | 3.2 视觉风格 |
| 三层架构与目录结构 | 七、架构分层与模块边界 |
| 协议定义（前后端合同） | 7.4 共享层：协议定义 |
| speech-swift API | 九、技术方向 → speech-swift 关键 API |
| 开发阶段划分 | 十、开发阶段 |
| 完整功能清单 | 十一、迁移清单 |

## 平台与约束

这是 **macOS 14+** 应用，不是 iOS。所有技术选型必须面向 macOS：
- **不能用 App Sandbox** — CGEventTap 与沙盒不兼容
- **录音浮窗必须用 NSPanel** — SwiftUI Window 无法实现 `NSFloatingWindowLevel` + 点击穿透 + 不抢焦点
- **Qwen3ASRModel 不是线程安全的** — VoiceService 和 MeetingService 各创建独立模型实例
- **CGEventTap 回调必须快速返回** — 重操作派发到后台线程，回调中只设标志位

## 开发原则

### 前后端解耦
前端只依赖 `Shared/` 层的协议和类型，不依赖后端具体实现。前端可用 Mock 独立开发，后端可用单元测试独立验证。两边通过 `@EnvironmentObject` + `@Published` 通信。

### 视觉风格
保留 Voice Aura 的 **Glassmorphism 风格**，色板和动画参数从 Python 版搬运（见 PROJECT.md 3.2）。布局结构参考 Type4Me 的两栏式设计。注意：Voice Aura 的配色是**自定义色板**，不是系统语义色。

### 从 Python 版翻译
`keyboard_listener.py`、`voice_service.py`、`config.py`、`meeting_service.py` 的核心逻辑可直接翻译。参考 PROJECT.md 第九章"可复用的代码/逻辑"表格。Python 版源码在 `/Users/zhangzheng/IDE project/Voice-Aura/`。

## Skill 路由

| 场景 | 使用的 Skill |
|------|------------|
| SwiftUI 两栏布局、窗口管理、AppKit 互操作、菜单栏、键盘快捷键 | `macos-hig-designer` |
| 毛玻璃材质、卡片/行/徽章组件、间距体系、SF Symbols 用法 | `liquid-glass`（含 `references/components.md` 和 `references/apple-hig.md`） |
| UI 整体设计评审、风格选择、调色板 | `ui-ux-pro-max`（全局 skill） |
| iOS/SwiftUI 通用开发模式（仅参考，注意过滤 iOS-only 内容） | `minimax-skills:ios-application-dev`（全局 plugin） |

### Skill 使用判断
- 写 SwiftUI 视图 → 先查 `liquid-glass` 的组件模式，再对照 `macos-hig-designer` 的 macOS 规范
- 做 NSPanel / AppKit 互操作 → 查 `macos-hig-designer` 第 10 节 AppKit Interop
- 做录音浮窗 → PROJECT.md 4.4 节定义了参数，`macos-hig-designer` 提供 NSPanel 的现代实践

## MCP / 工具路由

| 需要做的事 | 用什么 |
|-----------|-------|
| 查 speech-swift 库的最新 API 或 issue | `zread`（读 GitHub 仓库）或 `gh` CLI |
| 查 Apple 文档 / SwiftUI API | `perplexity_search` → `WebFetch` 验证 |
| 搜索 macOS 开发最佳实践 | `perplexity_search` |
| 读 Voice Aura Python 源码（翻译参考） | 直接 `Read` 工具读 `/Users/zhangzheng/IDE project/Voice-Aura/` |
| 跨会话搜索历史上下文 | `claude-mem` search（不传 project 参数可全量检索） |

## 开发阶段

```
Phase 1a: 共享层（协议冻结）     ← 必须最先完成
Phase 1b: 后端核心               ← 1a 完成后开始
Phase 2:  设置界面（可与 1b 并行）← 用 Mock 独立开发
Phase 3:  会议纪要               ← 需要 1b 稳定
Phase 4:  增强功能               ← 菜单栏、录音历史等
```

## 注意事项

- 会议纪要的转写**只执行语气词过滤**，不执行替换规则，不传热词
- 替换规则必须存储为**有序数组**，不能用 Swift Dictionary
- 剪贴板恢复前必须检查 `changeCount` 防止竞态
- 双 Command 触发会议时，正在进行的语音录音**立即取消**
