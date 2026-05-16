# LLM API 配置集中到「通用」设置 — 设计文档

日期：2026-05-16

## 背景与目标

当前 LLM（大模型）的 API 配置分散在两处：

- **语音页**（`VoiceSettingsSection`）：`AI 大模型（文本优化）` 卡片 — 提供商 / API Key / Base URL / 模型 / 启用开关
- **会议页**（`MeetingSettingsSection`）：`AI 大模型（内容处理）` 卡片 — 同样的字段

两张卡片字段重复，用户感觉冗余。本次重构把**纯 API 配置**（提供商、Key、URL、模型）集中到「通用」设置页统一管理，把**「是否启用」开关**留在语音页和会议页各自的位置。

### 用户决策（已确认）

1. 只搬 **AI 大模型的 API 配置**到通用页；ASR 模型、润色提示词、会议摘要提示词都留在原页。
2. **单一提供商**：通用页只有一个提供商选择，语音和会议共用同一家服务商、同一个 API Key、同一个 Base URL。
3. **模型分开**：语音和会议各有独立的「模型」输入框，可填不同模型名。
4. **启用开关留各页**：语音页保留「启用 AI 润色」开关，会议页保留「启用 AI 摘要」开关。
5. 通用页「AI 大模型」卡片位置：在 `隐私模式` 之后、`输入行为` 之前。

## 数据模型变更

### `ProviderCredentials`（`Shared/Types.swift`）

新增 `meetingModel` 字段。现有 `model` 字段语义收窄为「语音模型」。

```swift
struct ProviderCredentials: Codable, Equatable {
    var apiKey: String = ""
    var baseURL: String = ""
    var model: String = ""          // 语音模型
    var meetingModel: String = ""   // 会议模型；为空时回退到 model
}
```

**Codable 兼容性（关键）**：Swift 合成的 `Decodable` 不会对缺失的键应用默认值，会直接抛错。旧版持久化的 JSON 没有 `meetingModel` 键，因此必须为 `ProviderCredentials` 手写 `init(from:)`，对 `meetingModel` 用 `decodeIfPresent(...) ?? ""`。其余字段保持原逻辑。

**会议模型回退规则**：读取会议模型时统一用
`creds.meetingModel.isEmpty ? creds.model : creds.meetingModel`。
因此**无需任何一次性迁移代码** — 老用户的会议摘要在未单独设置会议模型前，自动沿用语音模型，与改动前行为一致。

### 移除 `meetingLLMProvider`

会议不再有独立提供商，统一用 `llmProvider`。移除该字段，避免双份真相来源：

- `Shared/AppConfig.swift`：删除 `meetingLLMProvider` 的 `@Published` 属性、`load`、`save` 三处。
- `Shared/Protocols.swift`：从 `ConfigManaging` 协议删除 `meetingLLMProvider`。
- `Backend/Services/ConfigManager.swift`：删除 `meetingLLMProvider` 访问器。
- `defaultMeetingLLMProvider` 默认值常量一并删除。

### 保留不动

- `meetingLLMCredentials` 及 `migrateMeetingCredentialsIfNeeded()`：仍是老数据一次性迁移源，保留。
- `cloudLLMEnabled`（语音启用）、`meetingLLMEnabled`（会议启用）：保留，开关绑定它们。
- `localLLMNotes`（润色提示词）、`meetingSummaryPrompt`（会议摘要提示词）：保留在各自页面。

## UI 变更

### 1. 通用页 — 新增「AI 大模型」卡片

新建组件文件 `Frontend/Components/LLMConfigCard.swift`，封装该卡片为独立 `View`。
`GeneralSettingsSection` 在 `隐私模式` 块与 `输入行为` 块之间嵌入 `LLMConfigCard()`。
（拆成独立组件是为了让 `GeneralSettingsSection` 保持在 250 行以内。）

卡片内容（一张 `glassCard`）：

```
┌─ 🧠 AI 大模型                        [云端] ─┐
│ 提供商   [OpenRouter ▾]                      │
│ API Key  [____________]                      │
│ Base URL [____________]                      │
│ ────────────────────────────────────         │
│ 语音模型 [openai/gpt-5.4-nano    ]            │
│ 会议模型 [____________  占位:默认同语音模型]   │
│ 🔗 语音输入与会议纪要共用此配置，               │
│    在「语音」「会议」页分别开启                  │
└──────────────────────────────────────────────┘
```

- **提供商 Picker**：绑定 `configManager.llmProvider`。`onChange` 时若 `llmCredentials` 无该 provider 条目，用 `provider.defaultBaseURL` / `defaultModel` 初始化（沿用现有逻辑）。
- **API Key / Base URL**：绑定 `llmCredentials[provider].apiKey` / `.baseURL`（`SecureField` / `TextField`）。
- **语音模型**：绑定 `llmCredentials[provider].model`。
- **会议模型**：绑定 `llmCredentials[provider].meetingModel`，占位文字提示「留空则与语音模型相同」。
- 复用 `credentialBinding` 式的 keyPath 绑定写法。
- 卡片不含启用开关。

### 2. 语音页改造（`VoiceSettingsSection`）

- **删除** `llmModelCard` 与 `cloudLLMContent`（provider/key/url 卡片整块）。
- **新增**紧凑卡片 `llmEnableCard` 放在原 `llmModelCard` 位置：
  - 图标 `brain` + 标题「AI 大模型（文本优化）」+ `云端` badge
  - 状态点（已启用/未启用）+ 开关，绑定 `configManager.cloudLLMEnabled`
  - 提示行：「提供商 / API Key / 模型 在『通用』设置中配置」
- `llmNotesView`（AI 转写润色提示词）**保留原位**，紧随其下。
- `body` 里其余卡片（录音按键、ASR、热词、替换规则）不动。

### 3. 会议页改造（`MeetingSettingsSection`）

- **删除** `meetingLLMView` 中的 提供商 / API Key / Base URL / 模型 四行，及 `meetingLLMCredentialBinding` 中与这些字段相关的部分（若不再被引用则整体删除）。
- **保留/新增**紧凑卡片：
  - 图标 `brain` + 标题「AI 大模型（内容处理）」+ `云端` badge
  - 状态点 + 开关，绑定 `configManager.meetingLLMEnabled`（沿用现有开关逻辑：开启时若摘要提示词为空则填默认）
  - 文案「录制结束后自动生成会议摘要」保留
  - 提示行：「提供商 / API Key / 模型 在『通用』设置中配置」
- `customPromptView`（会议摘要提示词）**保留原位**。
- `asrModelCard`（语音识别模型）**保留不动**。
- `migrateMeetingCredentialsIfNeeded()` 的 `.onAppear` 调用保留。

## 后端变更

### `MeetingSummarizer.createLLMClient()`

```swift
// 旧：configManager.meetingLLMProvider
guard let provider = LLMProvider(rawValue: configManager.llmProvider),
      provider != .none else { throw SummarizerError.notConfigured }

var creds = configManager.llmCredentials[provider.rawValue] ?? ProviderCredentials()
// 会议用会议模型；未单独设置时回退到语音模型
creds.model = creds.meetingModel.isEmpty ? creds.model : creds.meetingModel
```

即：构造传给 `LLMClient` 的 `ProviderCredentials` 时，把 `model` 替换为
`meetingModel.isEmpty ? model : meetingModel`。`apiKey` / `baseURL` 不变。

### `VoiceService`

不变 —— 仍读 `configManager.llmProvider` + `llmCredentials[provider].model`（语音模型）+ `cloudLLMEnabled`。

## 受影响文件清单

| 文件 | 改动 |
|------|------|
| `Shared/Types.swift` | `ProviderCredentials` 加 `meetingModel` + 手写 `init(from:)` |
| `Shared/AppConfig.swift` | 删除 `meetingLLMProvider`（属性/load/save/默认值） |
| `Shared/Protocols.swift` | `ConfigManaging` 删除 `meetingLLMProvider` |
| `Backend/Services/ConfigManager.swift` | 删除 `meetingLLMProvider` 访问器 |
| `Backend/Meeting/MeetingSummarizer.swift` | 改用 `llmProvider` + 会议模型回退 |
| `Frontend/Components/LLMConfigCard.swift` | **新增**：通用页 AI 大模型卡片 |
| `Frontend/Tabs/Sections/GeneralSettingsSection.swift` | 嵌入 `LLMConfigCard` |
| `Frontend/Tabs/Sections/VoiceSettingsSection.swift` | 删 provider 卡片，换紧凑启用卡片 |
| `Frontend/Tabs/Sections/MeetingSettingsSection.swift` | 删 provider 行，换紧凑启用卡片 |
| `VoiceBubble.xcodeproj/project.pbxproj` | 注册新文件 `LLMConfigCard.swift` |

## 验证

1. 命令行构建：`xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet`，重启应用。
2. 通用页出现「AI 大模型」卡片，提供商/Key/URL/语音模型/会议模型可编辑并持久化。
3. 语音页启用开关 + 润色提示词仍在；会议页启用开关 + 摘要提示词仍在；两页不再有 provider/key/url 字段。
4. 语音转写润色走语音模型；会议摘要走会议模型（会议模型留空时走语音模型）。
5. 旧版本升级：已持久化的 `llmCredentials`（无 `meetingModel` 键）能正常解码，不丢 Key。

## 不做的事（YAGNI）

- 不支持语音与会议用不同提供商（用户已确认单一提供商）。
- 不迁移 / 不新增一次性升级代码 —— 会议模型用读时回退即可。
- 不动 ASR 模型配置、不动提示词、不动替换规则与热词。
