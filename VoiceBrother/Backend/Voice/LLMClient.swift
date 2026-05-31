import Foundation

/// LLM client for text post-processing (Layer 3 of the text pipeline).
/// Supports OpenAI-compatible APIs and Claude's Messages API.
final class LLMClient: TextPolisher {

    private let provider: LLMProvider
    private let credentials: ProviderCredentials
    private let polishContext: PolishContext
    private let timeout: TimeInterval
    private let maxTokens: Int

    /// 旧签名：仅 userNotes。兼容现有调用方（如 MeetingSummarizer / 预热 ping）。
    convenience init(provider: LLMProvider, credentials: ProviderCredentials, userNotes: String,
                     timeout: TimeInterval = 15, maxTokens: Int = 2048) {
        self.init(provider: provider, credentials: credentials,
                  polishContext: PolishContext(userNotes: userNotes),
                  timeout: timeout, maxTokens: maxTokens)
    }

    /// 完整版：传 PolishContext。语音输入主路径用这个，把场景 / 历史 / 热词都喂进去。
    init(provider: LLMProvider, credentials: ProviderCredentials,
         polishContext: PolishContext,
         timeout: TimeInterval = 15, maxTokens: Int = 2048) {
        self.provider = provider
        self.credentials = credentials
        self.polishContext = polishContext
        self.timeout = timeout
        self.maxTokens = maxTokens
    }

    // MARK: - TextPolisher

    func polish(_ text: String) async throws -> String {
        let systemPrompt = Self.buildSystemPrompt(context: polishContext)
        let result = try await call(systemPrompt: systemPrompt, userMessage: text)

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        return trimmed
    }

    // MARK: - Direct Call (custom system prompt, used by MeetingSummarizer)

    func call(systemPrompt: String, userMessage: String) async throws -> String {
        if provider.usesAnthropicProtocol {
            return try await callClaudeAPI(systemPrompt: systemPrompt, userMessage: userMessage)
        } else {
            return try await callOpenAICompatibleAPI(systemPrompt: systemPrompt, userMessage: userMessage)
        }
    }

    // MARK: - OpenAI-Compatible API (OpenAI, DeepSeek, 智谱, 豆包, Kimi, Ollama)

    private func callOpenAICompatibleAPI(systemPrompt: String, userMessage: String) async throws -> String {
        let baseURL = credentials.baseURL.isEmpty ? provider.defaultBaseURL : credentials.baseURL
        let model = credentials.model.isEmpty ? provider.defaultModel : credentials.model

        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
            throw LLMError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // API key header (not needed for local Ollama without auth)
        if !credentials.apiKey.isEmpty {
            request.setValue("Bearer \(credentials.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ],
            "temperature": 0.3,
            "max_tokens": maxTokens
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.parseError
        }

        return content
    }

    // MARK: - Claude Messages API

    private func callClaudeAPI(systemPrompt: String, userMessage: String) async throws -> String {
        let baseURL = credentials.baseURL.isEmpty ? provider.defaultBaseURL : credentials.baseURL
        let model = credentials.model.isEmpty ? provider.defaultModel : credentials.model

        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/messages") else {
            throw LLMError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userMessage]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        // Anthropic Messages API returns a `content` array whose blocks may be
        // typed `thinking` / `tool_use` *before* the `text` block (extended
        // thinking is on by default for some models, e.g. glm-5.1). Pick the
        // first block that actually carries text instead of assuming index 0.
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.compactMap({ $0["text"] as? String }).first else {
            throw LLMError.parseError
        }

        return text
    }
}

// MARK: - Errors

enum LLMError: LocalizedError {
    case invalidURL
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "LLM API URL 无效"
        case .invalidResponse:
            return "LLM API 响应格式错误"
        case .apiError(let code, let message):
            return "LLM API 错误 (\(code)): \(message)"
        case .parseError:
            return "无法解析 LLM 响应"
        }
    }
}
