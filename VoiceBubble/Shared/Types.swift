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
    case error(String)

    var displayText: String {
        switch self {
        case .idle: return "空闲"
        case .recording: return "录制中"
        case .finishing: return "处理剩余音频..."
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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cmd_r: return "右 Command ⌘"
        case .cmd_l: return "左 Command ⌘"
        case .alt_r: return "右 Option ⌥"
        case .alt_l: return "左 Option ⌥"
        case .ctrl: return "Control ⌃"
        case .shift: return "Shift ⇧"
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
        }
    }

    var flagMask: CGEventFlags {
        switch self {
        case .cmd_r, .cmd_l: return .maskCommand
        case .alt_r, .alt_l: return .maskAlternate
        case .ctrl: return .maskControl
        case .shift: return .maskShift
        }
    }
}

// MARK: - Model Selection

enum ASRModel: String, CaseIterable, Identifiable {
    case small = "Qwen/Qwen3-ASR-0.6B"
    case large = "Qwen/Qwen3-ASR-1.7B"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: return "0.6B 极速模式"
        case .large: return "1.7B 精确模式"
        }
    }

    var huggingFaceId: String {
        switch self {
        case .small: return "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
        case .large: return "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
        }
    }

    var estimatedSize: String {
        switch self {
        case .small: return "~400MB"
        case .large: return "~2.5GB"
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

    init(id: UUID = UUID(), from: String, to: String) {
        self.id = id
        self.from = from
        self.to = to
    }
}
