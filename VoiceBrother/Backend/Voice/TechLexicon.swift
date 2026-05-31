import Foundation

/// 内置英文技术术语词典 — 给 LLM polish 当大小写参考，避免 ASR 输出
/// "app store" / "github" / "swift ui" 这类拼写。仅作 prompt 提示，
/// 不直接替换文本（替换交给 LLM 决定，因为有"我的 github 项目"这种合法
/// 小写场景，硬替换会误伤）。
///
/// 添加新词的判定标准：
///   • 一般性技术词（API、JSON、URL）→ 加
///   • 大牌产品/品牌（App Store、GitHub、Xcode、ChatGPT）→ 加
///   • 太冷门、只在某个圈子用 → 不加（让用户加到 VocabularyTab）
enum TechLexicon {

    /// 默认全集 — 按类别组织，方便日后增删。Prompt 里展开成扁平逗号串。
    static let defaults: [String] = [
        // —— Apple 生态 ——
        "macOS", "iOS", "iPadOS", "watchOS", "tvOS", "visionOS",
        "App Store", "Xcode", "Swift", "SwiftUI", "AppKit", "UIKit",
        "Combine", "Core Data", "TestFlight", "Vision Pro",

        // —— 主流开发工具/平台 ——
        "GitHub", "GitLab", "VS Code", "JetBrains", "IntelliJ", "PyCharm",
        "Cursor", "Claude Code", "Copilot",

        // —— Web / 前端 ——
        "JavaScript", "TypeScript", "Node.js", "React", "Next.js", "Vue", "Nuxt",
        "Tailwind", "HTML", "CSS", "Webpack", "Vite",

        // —— 后端 / 数据库 ——
        "Python", "Django", "FastAPI", "Flask", "Java", "Spring Boot",
        "Go", "Rust", "PostgreSQL", "MySQL", "MongoDB", "Redis", "SQLite",
        "Supabase", "Firebase",

        // —— API / 协议 ——
        "API", "JSON", "YAML", "XML", "HTTP", "HTTPS", "WebSocket",
        "REST", "GraphQL", "gRPC", "OAuth", "JWT", "URL", "URI",
        "SDK", "CLI", "GUI", "UI", "UX",

        // —— AI / 大模型 ——
        "ChatGPT", "GPT-4", "GPT-5", "Claude", "Claude Code", "Anthropic",
        "OpenAI", "DeepSeek", "Gemini", "Llama", "Qwen",
        "LLM", "RAG", "MCP", "ASR", "TTS", "VAD",
        "PyTorch", "TensorFlow", "MLX", "HuggingFace",

        // —— 协作 / 工作流 ——
        "PR", "MR", "CI", "CD", "DevOps", "Docker", "Kubernetes",
        "AWS", "GCP", "Azure", "Vercel", "Cloudflare",

        // —— 文件/格式 ——
        "PDF", "CSV", "Markdown", "LaTeX", "SVG", "PNG", "JPG", "MP4",

        // —— 通用缩写 ——
        "CPU", "GPU", "RAM", "SSD", "USB", "Wi-Fi", "Bluetooth",
    ]
}
