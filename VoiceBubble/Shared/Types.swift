import Foundation
import CoreGraphics

// MARK: - Service State

enum ServiceState: Equatable {
    case stopped
    case downloading
    case loading
    case ready
    case recording
    case transcribing
    case error(String)

    var isIdle: Bool {
        switch self {
        case .stopped, .error: return true
        default: return false
        }
    }

    var isActive: Bool {
        switch self {
        case .recording, .transcribing: return true
        default: return false
        }
    }

    var displayText: String {
        switch self {
        case .stopped: return "已停止"
        case .downloading: return "下载中..."
        case .loading: return "加载模型到内存中..."
        case .ready: return "运行中"
        case .recording: return "录音中..."
        case .transcribing: return "识别中..."
        case .error(let msg): return "错误: \(msg)"
        }
    }
}

// MARK: - Meeting State

enum MeetingState: Equatable {
    case idle
    case recording
    case finishing
    case summarizing
    case error(String)

    var displayText: String {
        switch self {
        case .idle: return "空闲"
        case .recording: return "录制中"
        case .finishing: return "处理剩余音频..."
        case .summarizing: return "生成会议摘要..."
        case .error(let msg): return "错误: \(msg)"
        }
    }
}

// MARK: - Download Progress

struct DownloadProgress: Equatable {
    let downloaded: Int64
    let total: Int64
    let description: String

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(downloaded) / Double(total)
    }

    var percentageText: String {
        guard total > 0 else { return "未知" }
        return "\(Int(fraction * 100))%"
    }
}

// MARK: - Permission Status

struct PermissionStatus: Equatable {
    let accessibility: Bool
    let microphone: Bool
    let screenRecording: Bool

    var allGranted: Bool {
        accessibility && microphone && screenRecording
    }

    static let notDetermined = PermissionStatus(accessibility: false, microphone: false, screenRecording: false)
}

// MARK: - Trigger Key

enum TriggerKey: String, CaseIterable, Identifiable {
    case cmd_r = "cmd_r"
    case cmd_l = "cmd_l"
    case alt_r = "alt_r"
    case alt_l = "alt_l"
    case ctrl = "ctrl"
    case shift = "shift"
    // Mouse side buttons — captured natively via CGEventTap's .otherMouseDown /
    // .otherMouseUp. Press-and-hold semantics work cleanly because we get
    // explicit down/up events (unlike Logi Options+ keystroke mapping which
    // collapses the hold into a single keypress).
    case mouse_btn3 = "mouse_btn3"   // Logitech 后退侧键 (default mapping)
    case mouse_btn4 = "mouse_btn4"   // Logitech 前进侧键 (default mapping)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cmd_r: return "右 Command ⌘"
        case .cmd_l: return "左 Command ⌘"
        case .alt_r: return "右 Option ⌥"
        case .alt_l: return "左 Option ⌥"
        case .ctrl: return "Control ⌃"
        case .shift: return "Shift ⇧"
        case .mouse_btn3: return "🖱 鼠标后退侧键"
        case .mouse_btn4: return "🖱 鼠标前进侧键"
        }
    }

    var keyCode: CGKeyCode {
        switch self {
        case .cmd_r: return 0x36
        case .cmd_l: return 0x37
        case .alt_r: return 0x3D
        case .alt_l: return 0x3A
        case .ctrl: return 0x3B
        case .shift: return 0x38
        // Mouse buttons don't have a keycode — listener routes via
        // mouseButtonNumber instead. Return 0 as a sentinel that won't match
        // any real keyboard event.
        case .mouse_btn3, .mouse_btn4: return 0
        }
    }

    var flagMask: CGEventFlags {
        switch self {
        case .cmd_r, .cmd_l: return .maskCommand
        case .alt_r, .alt_l: return .maskAlternate
        case .ctrl: return .maskControl
        case .shift: return .maskShift
        case .mouse_btn3, .mouse_btn4: return []
        }
    }

    /// Mouse button number for `.otherMouseDown` / `.otherMouseUp` events.
    /// Returns nil for keyboard triggers.
    var mouseButtonNumber: Int? {
        switch self {
        case .mouse_btn3: return 3
        case .mouse_btn4: return 4
        default: return nil
        }
    }

    var isMouseButton: Bool { mouseButtonNumber != nil }
}

// MARK: - Model Selection

enum ASRModel: String, CaseIterable, Identifiable {
    case small = "Qwen/Qwen3-ASR-0.6B"
    case large = "Qwen/Qwen3-ASR-1.7B"
    case apple = "apple_speech"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: return "0.6B 极速模式"
        case .large: return "1.7B 精确模式"
        case .apple: return "Apple 语音识别"
        }
    }

    var huggingFaceId: String {
        switch self {
        case .small: return "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
        case .large: return "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
        case .apple: return ""
        }
    }

    var estimatedSize: String {
        switch self {
        case .small: return "~400MB"
        case .large: return "~2.5GB"
        case .apple: return "系统内置"
        }
    }

    var fullName: String {
        switch self {
        case .small: return "Qwen3-ASR-0.6B"
        case .large: return "Qwen3-ASR-1.7B"
        case .apple: return "Apple Speech"
        }
    }

    var quantization: String {
        switch self {
        case .small: return "MLX 4bit"
        case .large: return "MLX 8bit"
        case .apple: return "Neural Engine"
        }
    }

    var isApple: Bool { self == .apple }
    var isQwen: Bool { !isApple }
}

// MARK: - Meeting Transcription Language

/// Language hint passed to Qwen3-ASR when transcribing meeting segments.
/// The model's accuracy degrades sharply when the wrong language is hinted —
/// a Japanese conversation transcribed under "Chinese" comes back as garbled
/// Mandarin homophones with token-loop hallucinations. Defaulting to Chinese
/// preserves the historical behaviour for existing users.
enum MeetingLanguage: String, CaseIterable, Identifiable, Codable {
    /// Auto-detect — passes nil to the ASR's language parameter so Qwen3-ASR
    /// drops the language token and decodes freely across CJK + Latin scripts.
    /// The right default for mixed-language users; pin a specific language
    /// only when auto-detect is making mistakes (e.g. very short utterances).
    case auto = "Auto"
    case chinese = "Chinese"
    case english = "English"
    case japanese = "Japanese"

    var id: String { rawValue }

    /// The string passed to Qwen3-ASR's `language` parameter, or nil for auto.
    var asrLanguageHint: String? {
        self == .auto ? nil : rawValue
    }

    var displayName: String {
        switch self {
        case .auto:     return "自动检测"
        case .chinese:  return "中文"
        case .english:  return "English"
        case .japanese: return "日本語"
        }
    }
}

// MARK: - Polish Model Selection

enum PolishModel: String, CaseIterable, Identifiable {
    case qwen3Chat = "aufklarer/Qwen3-0.6B-Chat-CoreML"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .qwen3Chat: return "0.6B 极速模式"
        }
    }

    var huggingFaceId: String { rawValue }

    var estimatedSize: String {
        switch self {
        case .qwen3Chat: return "~318MB"
        }
    }

    var fullName: String {
        switch self {
        case .qwen3Chat: return "Qwen3-Chat-0.6B"
        }
    }

    var quantization: String {
        switch self {
        case .qwen3Chat: return "CoreML INT4"
        }
    }
}

// MARK: - Transcription Record

struct TranscriptionRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let text: String
    /// Recording duration in seconds (approximate).
    let duration: Double

    init(id: UUID = UUID(), timestamp: Date = Date(), text: String, duration: Double = 0) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.duration = duration
    }
}

// MARK: - Replacement Rule

struct ReplacementRule: Identifiable, Equatable, Codable {
    let id: UUID
    var from: String
    var to: String
    var source: RuleSource

    enum RuleSource: String, Codable {
        case manual
        case learned
        case `default`
    }

    init(id: UUID = UUID(), from: String, to: String, source: RuleSource = .manual) {
        self.id = id
        self.from = from
        self.to = to
        self.source = source
    }

    // Backward-compatible decoding: existing saved rules without `source` default to .manual
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        from = try container.decode(String.self, forKey: .from)
        to = try container.decode(String.self, forKey: .to)
        source = try container.decodeIfPresent(RuleSource.self, forKey: .source) ?? .manual
    }
}

// MARK: - Correction Record

struct CorrectionRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let injectedText: String
    let correctedText: String
    let diffFrom: String
    let diffTo: String
    let bundleID: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        injectedText: String,
        correctedText: String,
        diffFrom: String,
        diffTo: String,
        bundleID: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.injectedText = injectedText
        self.correctedText = correctedText
        self.diffFrom = diffFrom
        self.diffTo = diffTo
        self.bundleID = bundleID
    }
}

// MARK: - Cloud ASR Provider

enum CloudASRProvider: String, CaseIterable, Identifiable, Codable {
    case openaiWhisper = "openai_whisper"
    case deepgram = "deepgram"
    case volcanoASR = "volcano_asr"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openaiWhisper: return "OpenAI Whisper"
        case .deepgram: return "Deepgram"
        case .volcanoASR: return "火山引擎 ASR"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openaiWhisper: return "https://api.openai.com/v1"
        case .deepgram: return "https://api.deepgram.com/v1"
        case .volcanoASR: return "https://openspeech.bytedance.com/api/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .openaiWhisper: return "whisper-1"
        case .deepgram: return "nova-2"
        case .volcanoASR: return "bigmodel"
        }
    }

    /// Whether the provider has a working engine. UI pickers must hide
    /// non-implemented cases so users don't pick something that throws
    /// "暂未实现" at recording time.
    var isImplemented: Bool {
        switch self {
        case .volcanoASR: return true
        case .openaiWhisper, .deepgram: return false
        }
    }
}

// MARK: - LLM Provider

enum LLMProvider: String, CaseIterable, Identifiable, Codable {
    case none = "none"
    case openai = "openai"
    case claude = "claude"
    case deepseek = "deepseek"
    case openRouter = "openrouter"
    case zhipu = "zhipu"
    case doubao = "doubao"
    case kimi = "kimi"
    case ollama = "ollama"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "不使用"
        case .openai: return "OpenAI (GPT)"
        case .claude: return "Claude (Anthropic)"
        case .deepseek: return "DeepSeek"
        case .openRouter: return "OpenRouter"
        case .zhipu: return "智谱 (GLM)"
        case .doubao: return "豆包 (字节跳动)"
        case .kimi: return "Kimi (月之暗面)"
        case .ollama: return "Ollama (本地)"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .none: return ""
        case .openai: return "https://api.openai.com/v1"
        case .claude: return "https://api.anthropic.com/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4"
        case .doubao: return "https://ark.cn-beijing.volces.com/api/v3"
        case .kimi: return "https://api.moonshot.cn/v1"
        case .ollama: return "http://localhost:11434/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .none: return ""
        case .openai: return "gpt-4o-mini"
        case .claude: return "claude-sonnet-4-6"
        case .deepseek: return "deepseek-chat"
        case .openRouter: return "google/gemini-2.0-flash-001"
        case .zhipu: return "glm-4-flash"
        case .doubao: return "doubao-1.5-pro-32k"
        case .kimi: return "moonshot-v1-8k"
        case .ollama: return "qwen2.5:7b"
        }
    }

    var isLocal: Bool { self == .ollama }
    var requiresAPIKey: Bool { !isLocal && self != .none }
}

// MARK: - Provider Credentials

struct ProviderCredentials: Codable, Equatable {
    var apiKey: String = ""
    var baseURL: String = ""
    var model: String = ""
}

// MARK: - Prompt Preset

/// A named, reusable prompt template the user can swap into the active
/// 润色 / 摘要 textarea. Built-in presets are hardcoded; user-saved
/// presets are persisted as `[name: prompt]` in AppConfig.
struct PromptPreset: Identifiable, Hashable {
    let id: String      // Stable identifier — equals name for user presets, prefix-tagged for built-ins
    let name: String
    let prompt: String
    let isBuiltIn: Bool

    static let builtInPolishPresets: [PromptPreset] = [
        PromptPreset(id: "builtin.polish.default", name: "默认（书面化）",
                     prompt: "保持原意不变，修正口语化表达，补充缺失的标点符号。不要添加原文没有的内容。",
                     isBuiltIn: true),
        PromptPreset(id: "builtin.polish.wechat", name: "公众号风格",
                     prompt: "保留长句和书面化表达，适度补充段落连接词，让文字更适合公众号阅读。保留所有英文专有名词不翻译。",
                     isBuiltIn: true),
        PromptPreset(id: "builtin.polish.xhs", name: "小红书风格",
                     prompt: "改写为小红书风格：短句、口语、活泼。可适度添加 emoji（不超过 3 个），保留口气和情绪。",
                     isBuiltIn: true),
        PromptPreset(id: "builtin.polish.tech", name: "技术写作",
                     prompt: "保留所有英文术语、代码标识符、命令行指令的原样形式。不要把 \"Claude Code\" 翻译成中文。修正口语和标点，保留技术准确度。",
                     isBuiltIn: true),
        PromptPreset(id: "builtin.polish.email", name: "正式邮件",
                     prompt: "改写为正式邮件语气：得体、客气、措辞严谨。补充称呼/结尾若上下文需要。",
                     isBuiltIn: true),
    ]

    /// The rich default meeting-summary prompt. Lives here so the
    /// "默认（对话整理）" built-in preset, the freshly-installed default
    /// stored in AppConfig, and any place else that wants the canonical
    /// dialog-format instructions all point to the same string.
    static let defaultMeetingDialogPrompt = """
    你是会议纪要整理助手。请根据以下会议转写文本，整理为人物对话格式。

    要求：
    1. 识别参会者，根据对话内容、称呼和语境推断发言者身份，用 A、B、C 等标注
    2. 将内容整理为逐句对话格式，例如：A：…… B：…… A：…… B：……
    3. 修正语音识别中的错别字和不通顺的表达，保持原意
    4. 不要添加时间戳，不要添加原文没有的内容

    只输出整理后的对话内容，不要解释你的处理过程。
    """

    static let builtInMeetingPresets: [PromptPreset] = [
        PromptPreset(id: "builtin.meeting.default", name: "默认（对话整理）",
                     prompt: defaultMeetingDialogPrompt,
                     isBuiltIn: true),
        PromptPreset(id: "builtin.meeting.review", name: "产品评审",
                     prompt: "按议题分类整理（背景 / 讨论 / 决议 / 待办），明确每个待办项的负责人和截止时间。",
                     isBuiltIn: true),
        PromptPreset(id: "builtin.meeting.weekly", name: "周会",
                     prompt: "按人或按项目整理上周进度、本周计划、阻塞事项。简洁的子弹列表。",
                     isBuiltIn: true),
        PromptPreset(id: "builtin.meeting.oneonone", name: "1on1",
                     prompt: "整理为话题清单：聊到的内容、决定、跟进项。语气保持中性、客观。",
                     isBuiltIn: true),
        PromptPreset(id: "builtin.meeting.interview", name: "客户访谈",
                     prompt: "保留用户原话和情绪关键词。按问题分组：用户提到的痛点 / 期望 / 现有方案 / 引语。",
                     isBuiltIn: true),
    ]
}

