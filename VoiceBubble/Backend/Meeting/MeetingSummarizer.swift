import Foundation

/// Turns a raw meeting transcription into a summary document. The LLM does
/// three things, all hardcoded — there is no user-editable prompt anymore:
///   1. clean & restore the raw transcription (fix ASR errors, drop fillers,
///      keep the original wording, no speaker labels)
///   2. write a summary of the cleaned text
///   3. generate a title for the whole recording
@MainActor
final class MeetingSummarizer {

    private let configManager: ConfigManager

    /// Max input chars per cleaning call. The cleaning step's output is
    /// roughly the same size as its input, so each chunk must stay small
    /// enough that the cleaned result still fits in the `llmMaxTokens`
    /// output budget.
    private static let cleanChunkSize = 5_000
    /// Safety cap on the text fed to the title/summary call. Meetings rarely
    /// produce this much cleaned text; beyond it the tail is dropped to keep
    /// the request within sane bounds.
    private static let summaryInputCap = 50_000
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

        let client = try createLLMClient()

        // Step 1 — clean & restore the raw transcription.
        let cleaned = try await cleanTranscript(body: body, client: client)

        // Step 2 — generate a title and a summary from the cleaned text.
        let (title, summary) = try await titleAndSummary(cleanedText: cleaned, client: client)

        // Assemble and write the summary document.
        let transcriptURL = URL(fileURLWithPath: transcriptPath)
        let summaryURL = summaryFileURL(transcriptURL: transcriptURL, title: title)
        let now = Self.dateFormatter.string(from: Date())

        let content = """
        # \(title)

        - 原始记录：\(transcriptURL.lastPathComponent)
        - 生成时间：\(now)

        ---

        ## 摘要

        \(summary)

        ## 全文整理

        \(cleaned)
        """

        try content.write(to: summaryURL, atomically: true, encoding: .utf8)
        return summaryURL.path
    }

    // MARK: - Step 1: Clean Transcript

    /// Cleans the transcription chunk by chunk and concatenates the result.
    /// A chunk that fails to clean falls back to its raw text so no content
    /// is lost; only when *every* chunk fails does the whole step error out.
    private func cleanTranscript(body: String, client: LLMClient) async throws -> String {
        let chunks = splitIntoChunks(body, maxSize: Self.cleanChunkSize)
        var cleanedParts: [String] = []
        var errors: [String] = []
        var successCount = 0

        for (index, chunk) in chunks.enumerated() {
            let rawChunk = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                let result = try await client.call(systemPrompt: Self.cleanSystemPrompt, userMessage: chunk)
                let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    cleanedParts.append(rawChunk)
                } else {
                    cleanedParts.append(trimmed)
                    successCount += 1
                }
            } catch {
                errors.append("第 \(index + 1) 段整理失败: \(error.localizedDescription)")
                cleanedParts.append(rawChunk)
            }
        }

        guard successCount > 0 else {
            throw SummarizerError.allChunksFailed(errors.joined(separator: "; "))
        }

        var joined = cleanedParts.joined(separator: "\n\n")
        if !errors.isEmpty {
            joined += "\n\n> 注意：部分内容整理失败，已保留原始转写 - \(errors.joined(separator: "; "))"
        }
        return joined
    }

    // MARK: - Step 2: Title & Summary

    private func titleAndSummary(cleanedText: String, client: LLMClient) async throws -> (title: String, summary: String) {
        var input = cleanedText
        if input.count > Self.summaryInputCap {
            input = String(input.prefix(Self.summaryInputCap)) + "\n\n（后续内容略）"
        }

        let response = try await client.call(systemPrompt: Self.titleSummarySystemPrompt, userMessage: input)
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SummarizerError.emptyResponse
        }
        return parseTitleAndSummary(trimmed)
    }

    /// Parses the `标题：…` first line out of the model's response. Falls back
    /// to a date-based title and treats the whole response as the summary
    /// when the model doesn't follow the format.
    private func parseTitleAndSummary(_ raw: String) -> (title: String, summary: String) {
        let lines = raw.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if let titleRange = t.range(of: "标题：") ?? t.range(of: "标题:") {
                let title = String(t[titleRange.upperBound...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " *#《》\"'「」"))
                let summary = lines[(index + 1)...].joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (title.isEmpty ? Self.fallbackTitle() : title,
                        summary.isEmpty ? raw : summary)
            }
            // First non-empty line isn't a title — give up parsing.
            break
        }
        return (Self.fallbackTitle(), raw)
    }

    private static func fallbackTitle() -> String {
        "录音摘要 " + dateFormatter.string(from: Date())
    }

    // MARK: - Prompts

    private static let cleanSystemPrompt = """
    你是录音转写整理助手。下面是一段由语音识别得到的文本，可能有错别字、识别错误、口语和缺失的标点。请整理这段文本：
    - 修正明显的错别字和语音识别错误
    - 补全标点，按语义合理分段
    - 去除「嗯」「啊」「那个」「就是说」之类的无意义语气词和口头禅
    - 尽量保留原话，不要概括、不要改写语义、不要补充原文没有的内容
    - 不要区分或标注说话人，输出连续的正文

    只输出整理后的正文，不要任何说明或解释。
    """

    private static let titleSummarySystemPrompt = """
    下面是一段录音的整理后文本。请完成两件事：
    1. 拟一个简洁的标题，能概括主要内容，不超过 20 个字，不要书名号或引号
    2. 写一段摘要：先用一两句话概述，再用要点列出讨论的主要内容、达成的决议、待办事项（没有的部分可省略）

    严格按以下格式输出，不要其他任何内容：
    标题：<标题>

    <摘要正文>
    """

    // MARK: - LLM Client

    private func createLLMClient() throws -> LLMClient {
        // Meeting shares the voice LLM provider — there is no separate
        // meeting provider anymore.
        guard let provider = LLMProvider(rawValue: configManager.llmProvider),
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
        var creds = configManager.llmCredentials[provider.rawValue] ?? ProviderCredentials()
        if provider.requiresAPIKey && creds.apiKey.isEmpty {
            throw SummarizerError.missingAPIKey
        }
        // Meeting uses its own model; falls back to the voice model when the
        // user hasn't set a separate meeting model.
        creds.model = creds.meetingModel.isEmpty ? creds.model : creds.meetingModel

        return LLMClient(provider: provider, credentials: creds, userNotes: "",
                         timeout: Self.llmTimeout, maxTokens: Self.llmMaxTokens)
    }

    // MARK: - Helpers

    /// Splits text into chunks no larger than `maxSize`, preferring paragraph
    /// then line boundaries, hard-splitting by character count only as a last
    /// resort so an unusually long unbroken passage still fits the budget.
    private func splitIntoChunks(_ text: String, maxSize: Int) -> [String] {
        func pack(_ pieces: [String], separator: String) -> [String] {
            var chunks: [String] = []
            var current = ""
            for piece in pieces {
                if current.isEmpty {
                    current = piece
                } else if current.count + separator.count + piece.count <= maxSize {
                    current += separator + piece
                } else {
                    chunks.append(current)
                    current = piece
                }
            }
            if !current.isEmpty { chunks.append(current) }
            return chunks
        }

        var result: [String] = []
        for chunk in pack(text.components(separatedBy: "\n\n"), separator: "\n\n") {
            if chunk.count <= maxSize {
                result.append(chunk)
                continue
            }
            // Paragraph too big — repack by line.
            for sub in pack(chunk.components(separatedBy: "\n"), separator: "\n") {
                if sub.count <= maxSize {
                    result.append(sub)
                    continue
                }
                // Still too big — hard-split by character count.
                var rest = Substring(sub)
                while !rest.isEmpty {
                    let end = rest.index(rest.startIndex, offsetBy: maxSize,
                                         limitedBy: rest.endIndex) ?? rest.endIndex
                    result.append(String(rest[..<end]))
                    rest = rest[end...]
                }
            }
        }
        return result.isEmpty ? [text] : result
    }

    private func extractBody(from transcript: String) -> String {
        if let range = transcript.range(of: "---\n\n") {
            return String(transcript[range.upperBound...])
        }
        return transcript
    }

    /// Builds the summary file URL: `<标题>_<时间戳>_摘要.md`, alongside the
    /// transcript. The `yyyy-MM-dd_HH-mm-ss` timestamp is carried over from
    /// the transcript filename so History grouping and `--retranscribe`
    /// (both key off that substring) keep working.
    private func summaryFileURL(transcriptURL: URL, title: String) -> URL {
        let dir = transcriptURL.deletingLastPathComponent()
        let safeTitle = Self.sanitizeForFilename(title)
        let stem: String
        if let timestamp = Self.extractTimestamp(from: transcriptURL.lastPathComponent) {
            stem = "\(safeTitle)_\(timestamp)_摘要"
        } else {
            stem = "\(safeTitle)_摘要"
        }
        return dir.appendingPathComponent(stem + ".md")
    }

    private static func extractTimestamp(from filename: String) -> String? {
        let pattern = "[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        guard let m = regex.firstMatch(in: filename, range: range),
              let r = Range(m.range, in: filename) else { return nil }
        return String(filename[r])
    }

    /// Strips characters illegal/risky in a filename, collapses whitespace,
    /// and truncates. Falls back to "录音摘要" when nothing usable remains.
    private static func sanitizeForFilename(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = raw.components(separatedBy: illegal).joined(separator: " ")
        let collapsed = cleaned.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        if collapsed.isEmpty { return "录音摘要" }
        return String(collapsed.prefix(30))
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
            return "录音内容为空，无法生成摘要"
        case .emptyResponse:
            return "AI 返回了空的摘要结果"
        case .notConfigured:
            return "请先配置录音摘要 AI 模型"
        case .missingAPIKey:
            return "请先配置 API Key"
        case .allChunksFailed(let detail):
            return "所有分段整理均失败: \(detail)"
        }
    }
}
