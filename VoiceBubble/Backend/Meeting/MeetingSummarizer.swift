import Foundation

/// Generates LLM-powered meeting summaries from transcription files.
@MainActor
final class MeetingSummarizer {

    private let configManager: ConfigManager

    private static let chunkThreshold = 60_000
    private static let llmTimeout: TimeInterval = 120
    private static let llmMaxTokens = 8192

    init(configManager: ConfigManager) {
        self.configManager = configManager
    }

    // MARK: - Public API

    @discardableResult
    func summarize(transcriptPath: String) async throws -> String {
        let transcript = try String(contentsOfFile: transcriptPath, encoding: .utf8)

        let body = extractBody(from: transcript)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummarizerError.emptyTranscript
        }

        let systemPrompt = buildSystemPrompt()
        let client = try createLLMClient()

        let summary: String
        if body.count > Self.chunkThreshold {
            summary = try await summarizeChunked(body: body, systemPrompt: systemPrompt, client: client)
        } else {
            summary = try await client.call(systemPrompt: systemPrompt, userMessage: body)
        }

        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SummarizerError.emptyResponse
        }

        let transcriptURL = URL(fileURLWithPath: transcriptPath)
        let baseName = transcriptURL.deletingPathExtension().lastPathComponent
        let summaryURL = transcriptURL.deletingLastPathComponent().appendingPathComponent(baseName + "_会议摘要.md")
        let originalFilename = transcriptURL.lastPathComponent
        let now = Self.dateFormatter.string(from: Date())

        let content = """
        # 会议摘要

        - 原始记录：\(originalFilename)
        - 生成时间：\(now)

        ---

        \(trimmed)
        """

        try content.write(to: summaryURL, atomically: true, encoding: .utf8)
        return summaryURL.path
    }

    // MARK: - Prompt Building

    private func buildSystemPrompt() -> String {
        let customPrompt = configManager.meetingSummaryPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        if customPrompt.isEmpty {
            return ""
        } else {
            return """
            你是会议纪要整理助手。请根据以下会议转写文本，按用户要求生成会议摘要。同时修正语音识别中的错别字，根据上下文推断并标注发言者。只输出会议摘要，不要解释。

            用户要求：\(customPrompt)
            """
        }
    }

    /// Re-exported for callers that still reference the old name. The canonical
    /// source now lives in `PromptPreset.defaultMeetingDialogPrompt` so the
    /// built-in template picker, the fresh-install default, and any fallback
    /// path all stay in sync.
    static let defaultPrompt = PromptPreset.defaultMeetingDialogPrompt

    // MARK: - LLM Client

    private func createLLMClient() throws -> LLMClient {
        guard let provider = LLMProvider(rawValue: configManager.meetingLLMProvider),
              provider != .none else {
            throw SummarizerError.notConfigured
        }

        // Read from the shared `llmCredentials` dictionary — the meeting
        // settings UI's text fields write directly there (see
        // `meetingLLMCredentialBinding`). The legacy `meetingLLMCredentials`
        // dict is only used as a one-shot migration source on first launch
        // (see `migrateMeetingCredentialsIfNeeded`); reading it at runtime
        // would always return an empty `ProviderCredentials()` and cause the
        // summary to fail with `missingAPIKey` even after the user filled in
        // the API key. This was a real, reproducible bug.
        let creds = configManager.llmCredentials[provider.rawValue] ?? ProviderCredentials()
        if provider.requiresAPIKey && creds.apiKey.isEmpty {
            throw SummarizerError.missingAPIKey
        }

        return LLMClient(provider: provider, credentials: creds, userNotes: "",
                         timeout: Self.llmTimeout, maxTokens: Self.llmMaxTokens)
    }

    // MARK: - Chunking

    private func summarizeChunked(body: String, systemPrompt: String, client: LLMClient) async throws -> String {
        let segments = body.components(separatedBy: "\n\n")
        var chunks: [String] = []
        var current = ""

        for segment in segments {
            if current.count + segment.count + 2 > Self.chunkThreshold && !current.isEmpty {
                chunks.append(current)
                current = segment
            } else {
                if !current.isEmpty { current += "\n\n" }
                current += segment
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }

        var chunkSummaries: [String] = []
        var errors: [String] = []

        for (index, chunk) in chunks.enumerated() {
            let chunkPrompt = "\(systemPrompt)\n\n注意：这是会议转写的第 \(index + 1)/\(chunks.count) 部分。"
            do {
                let result = try await client.call(systemPrompt: chunkPrompt, userMessage: chunk)
                let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    chunkSummaries.append(trimmed)
                }
            } catch {
                errors.append("第 \(index + 1) 部分失败: \(error.localizedDescription)")
            }
        }

        guard !chunkSummaries.isEmpty else {
            throw SummarizerError.allChunksFailed(errors.joined(separator: "; "))
        }

        if chunks.count > 1 && chunkSummaries.count > 1 {
            let mergePrompt = "以下是同一会议分段摘要，请合并为一份完整的结构化会议摘要。保留所有关键信息，去除重复内容。"
            let merged = try await client.call(
                systemPrompt: mergePrompt,
                userMessage: chunkSummaries.joined(separator: "\n\n---\n\n")
            )
            let trimmed = merged.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if !errors.isEmpty {
                    return trimmed + "\n\n> 注意：部分内容摘要失败 - \(errors.joined(separator: "; "))"
                }
                return trimmed
            }
        }

        let result = chunkSummaries.joined(separator: "\n\n---\n\n")
        if !errors.isEmpty {
            return result + "\n\n> 注意：部分内容摘要失败 - \(errors.joined(separator: "; "))"
        }
        return result
    }

    // MARK: - Helpers

    private func extractBody(from transcript: String) -> String {
        if let range = transcript.range(of: "---\n\n") {
            return String(transcript[range.upperBound...])
        }
        return transcript
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

// MARK: - Errors

enum SummarizerError: LocalizedError {
    case emptyTranscript
    case emptyResponse
    case notConfigured
    case missingAPIKey
    case allChunksFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "会议记录内容为空，无法生成摘要"
        case .emptyResponse:
            return "AI 返回了空的摘要结果"
        case .notConfigured:
            return "请先配置会议摘要 AI 模型"
        case .missingAPIKey:
            return "请先配置 API Key"
        case .allChunksFailed(let detail):
            return "所有分段摘要均失败: \(detail)"
        }
    }
}
