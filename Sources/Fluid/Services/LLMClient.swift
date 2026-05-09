import Foundation

// MARK: - Error Types

enum LLMError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String)
    case networkError(Error)
    case encodingError
    case timeout(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response from LLM"
        case let .httpError(code, message):
            return "HTTP \(code): \(message)"
        case let .networkError(error):
            return "Network error: \(error.localizedDescription)"
        case .encodingError:
            return "Failed to encode request"
        case let .timeout(seconds):
            return "Request timed out after \(Int(seconds)) seconds"
        }
    }
}

// MARK: - LLMClient

/// Unified LLM communication layer for all modes (Transcription, Command, Rewrite).
/// Handles HTTP requests, SSE streaming, thinking token extraction, and tool call parsing.
@MainActor
final class LLMClient {
    static let shared = LLMClient()

    /// Default timeout for LLM requests (30 seconds)
    static let defaultTimeoutSeconds: TimeInterval = 30

    /// URLSession configured with appropriate timeouts
    private let session: URLSession

    private enum APIFormat {
        case chatCompletions
        case responses
        case anthropicMessages
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.defaultTimeoutSeconds
        config.timeoutIntervalForResource = Self.defaultTimeoutSeconds * 2 // Allow extra time for resource loading
        self.session = URLSession(configuration: config)
    }

    init(session: URLSession) {
        self.session = session
    }

    // MARK: - Response Types

    struct Response {
        /// Extracted <think>...</think> content (nil if none)
        let thinking: String?
        /// Main response content with thinking tags stripped
        let content: String
        /// Parsed tool calls for agentic modes (nil if none)
        let toolCalls: [ToolCall]
    }

    struct ToolCall {
        let id: String
        let name: String
        let arguments: [String: Any]

        /// Get a string argument by key
        func getString(_ key: String) -> String? {
            return self.arguments[key] as? String
        }

        /// Get an optional string argument, returning nil if empty
        func getOptionalString(_ key: String) -> String? {
            guard let value = arguments[key] as? String, !value.isEmpty else { return nil }
            return value
        }
    }

    // MARK: - Configuration

    struct Config {
        let messages: [[String: Any]]
        let providerID: String?
        let model: String
        let baseURL: String
        let apiKey: String
        let streaming: Bool
        let tools: [[String: Any]]
        let temperature: Double?

        /// Optional token limit (max_tokens/max_completion_tokens for chat, max_output_tokens for responses)
        var maxTokens: Int?

        /// Extra parameters to add to the request body (e.g., reasoning_effort, enable_thinking)
        /// These are model-specific and come from user settings
        var extraParameters: [String: Any]

        // Retry configuration
        var maxRetries: Int = 3
        var retryDelayMs: Int = 200

        // Timeout configuration (nil = use default)
        var timeoutSeconds: TimeInterval?

        // Optional real-time callbacks (for streaming UI updates)
        var onThinkingStart: (() -> Void)?
        var onThinkingChunk: ((String) -> Void)?
        var onThinkingEnd: (() -> Void)?
        var onContentChunk: ((String) -> Void)?
        var onToolCallStart: ((String) -> Void)?

        init(
            messages: [[String: Any]],
            providerID: String? = nil,
            model: String,
            baseURL: String,
            apiKey: String,
            streaming: Bool = true,
            tools: [[String: Any]] = [],
            temperature: Double? = nil,
            maxTokens: Int? = nil,
            extraParameters: [String: Any] = [:]
        ) {
            self.messages = messages
            self.providerID = providerID
            self.model = model
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.streaming = streaming
            self.tools = tools
            self.temperature = temperature
            self.maxTokens = maxTokens
            self.extraParameters = extraParameters
        }
    }

    // MARK: - Routing Abstractions

    private enum ProviderFamily {
        case anthropic
        case openAICompatible
    }

    private struct RoutePlan {
        let primaryFormat: APIFormat
        let fallbackFormat: APIFormat?
    }

    private struct PreparedRequest {
        var request: URLRequest
        let format: APIFormat
    }

    private protocol APIRouteStrategy {
        var format: APIFormat { get }
        func endpoint(for baseURL: String) -> String
        func applyHeaders(apiKey: String, request: inout URLRequest)
    }

    private struct AnthropicMessagesRouteStrategy: APIRouteStrategy {
        let format: APIFormat = .anthropicMessages

        func endpoint(for baseURL: String) -> String {
            if baseURL.contains("/messages") {
                return baseURL
            }

            let base = baseURL.isEmpty ? ModelRepository.shared.defaultBaseURL(for: "anthropic") : baseURL
            return "\(base)/messages"
        }

        func applyHeaders(apiKey: String, request: inout URLRequest) {
            if !apiKey.isEmpty {
                request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
            }
            request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
    }

    private struct ResponsesRouteStrategy: APIRouteStrategy {
        let format: APIFormat = .responses

        func endpoint(for baseURL: String) -> String {
            if baseURL.contains("/responses") {
                return baseURL
            }

            if baseURL.contains("/chat/completions") {
                return baseURL.replacingOccurrences(of: "/chat/completions", with: "/responses")
            }

            if baseURL.contains("/api/chat") || baseURL.contains("/api/generate") {
                // Some OpenAI-compatible providers only expose chat-style paths.
                // We still attempt Responses schema first and rely on fallback to chat completions.
                return baseURL
            }

            let base = baseURL.isEmpty ? ModelRepository.shared.defaultBaseURL(for: "openai") : baseURL
            return "\(base)/responses"
        }

        func applyHeaders(apiKey: String, request: inout URLRequest) {
            if !apiKey.isEmpty {
                request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
    }

    private struct ChatCompletionsRouteStrategy: APIRouteStrategy {
        let format: APIFormat = .chatCompletions

        func endpoint(for baseURL: String) -> String {
            if baseURL.contains("/chat/completions") || baseURL.contains("/api/chat") || baseURL.contains("/api/generate") {
                return baseURL
            }

            if baseURL.contains("/responses") {
                return baseURL.replacingOccurrences(of: "/responses", with: "/chat/completions")
            }

            let base = baseURL.isEmpty ? ModelRepository.shared.defaultBaseURL(for: "openai") : baseURL
            return "\(base)/chat/completions"
        }

        func applyHeaders(apiKey: String, request: inout URLRequest) {
            if !apiKey.isEmpty {
                request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
    }

    private func providerFamily(for config: Config) -> ProviderFamily {
        if let providerID = config.providerID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           providerID == "anthropic"
        {
            return .anthropic
        }

        let baseURL = config.baseURL.lowercased()
        if baseURL.contains("anthropic.com") {
            return .anthropic
        }

        return .openAICompatible
    }

    private func routePlan(for config: Config) -> RoutePlan {
        switch self.providerFamily(for: config) {
        case .anthropic:
            return RoutePlan(primaryFormat: .anthropicMessages, fallbackFormat: nil)
        case .openAICompatible:
            return RoutePlan(primaryFormat: .responses, fallbackFormat: .chatCompletions)
        }
    }

    private func routeStrategy(for format: APIFormat) -> any APIRouteStrategy {
        switch format {
        case .anthropicMessages:
            return AnthropicMessagesRouteStrategy()
        case .responses:
            return ResponsesRouteStrategy()
        case .chatCompletions:
            return ChatCompletionsRouteStrategy()
        }
    }

    // MARK: - Main Entry Point

    /// Make an LLM API call with the given configuration.
    /// Supports both streaming and non-streaming modes.
    /// Handles thinking token extraction, tool call parsing, and retries.
    func call(_ config: Config) async throws -> Response {
        let routePlan = self.routePlan(for: config)
        var preparedRequest = try self.buildRequest(config, forcedFormat: routePlan.primaryFormat)

        // Apply timeout to the request itself
        let timeout = config.timeoutSeconds ?? Self.defaultTimeoutSeconds
        preparedRequest.request.timeoutInterval = timeout

        self.logRequest(preparedRequest.request)

        // Execute the request. We rely on URLRequest/URLSession timeouts (30s default) rather
        // than racing a separate "timeout task". A task-group timeout wrapper can accidentally
        // keep the caller suspended until the full timeout elapses, which is the exact stall
        // we want to eliminate for overlay responsiveness.
        return try await self.executeWithRetry(
            request: preparedRequest,
            config: config,
            routePlan: routePlan
        )
    }

    /// Execute request with retry logic (extracted for timeout wrapper)
    private func executeWithRetry(request: PreparedRequest, config: Config, routePlan: RoutePlan) async throws -> Response {
        var currentRequest = request
        var attemptedResponsesFallback = false
        var lastError: Error?

        for attempt in 1...config.maxRetries {
            do {
                if config.streaming {
                    return try await self.processStreaming(request: currentRequest.request, format: currentRequest.format, config: config)
                } else {
                    return try await self.processNonStreaming(request: currentRequest.request, format: currentRequest.format)
                }
            } catch let LLMError.httpError(code, message)
                where !attemptedResponsesFallback &&
                currentRequest.format == .responses &&
                routePlan.fallbackFormat != nil &&
                self.shouldFallbackToChat(statusCode: code, message: message)
            {
                attemptedResponsesFallback = true
                DebugLogger.shared.warning(
                    "LLMClient: Responses endpoint rejected request (HTTP \(code)); falling back to chat completions",
                    source: "LLMClient"
                )
                guard let fallbackFormat = routePlan.fallbackFormat else { continue }
                currentRequest = try self.buildRequest(config, forcedFormat: fallbackFormat)
                currentRequest.request.timeoutInterval = config.timeoutSeconds ?? Self.defaultTimeoutSeconds
                continue
            } catch let error as URLError where self.isRetryableError(error) {
                lastError = error
                DebugLogger.shared.warning("LLMClient: Retry \(attempt)/\(config.maxRetries) due to \(error.code.rawValue)", source: "LLMClient")
                if attempt < config.maxRetries {
                    // Exponential backoff
                    let delayNs = UInt64(config.retryDelayMs * 1_000_000 * attempt)
                    try? await Task.sleep(nanoseconds: delayNs)
                    continue
                }
            } catch {
                throw error // Non-retryable error
            }
        }

        throw lastError ?? LLMError.networkError(
            NSError(domain: "LLMClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Request failed after retries"])
        )
    }

    // MARK: - Request Building

    private func buildRequest(_ config: Config, forcedFormat: APIFormat? = nil) throws -> PreparedRequest {
        let baseURL = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = self.routePlan(for: config)
        let apiFormat = forcedFormat ?? plan.primaryFormat
        let strategy = self.routeStrategy(for: apiFormat)
        let endpoint = strategy.endpoint(for: baseURL)

        guard let url = URL(string: endpoint) else {
            throw LLMError.invalidURL
        }

        // Build request body
        let body: [String: Any]
        switch apiFormat {
        case .chatCompletions:
            body = self.buildChatCompletionsBody(config)
        case .responses:
            body = self.buildResponsesBody(config)
        case .anthropicMessages:
            body = self.buildAnthropicMessagesBody(config)
        }

        // Serialize to JSON
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body, options: []) else {
            throw LLMError.encodingError
        }

        // Log the request for debugging
        let messageCount = config.messages.count
        if let bodyStr = String(data: jsonData, encoding: .utf8) {
            let truncated = bodyStr.count > 500 ? String(bodyStr.prefix(500)) + "..." : bodyStr
            DebugLogger.shared.debug("LLMClient: Request (\(messageCount) messages, model=\(config.model), streaming=\(config.streaming)): \(truncated)", source: "LLMClient")
        }

        // Build URLRequest
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        strategy.applyHeaders(apiKey: config.apiKey, request: &request)

        request.httpBody = jsonData

        return PreparedRequest(request: request, format: apiFormat)
    }

    private func buildChatCompletionsBody(_ config: Config) -> [String: Any] {
        var body: [String: Any] = [
            "model": config.model,
            "messages": config.messages,
        ]

        if let temp = config.temperature {
            body["temperature"] = temp
        }

        if !config.tools.isEmpty {
            body["tools"] = self.normalizeToolsForChatCompletions(config.tools)
            body["tool_choice"] = "auto"
        }

        if config.streaming {
            body["stream"] = true
        }

        let modelExtras = ThinkingParserFactory.getExtraParameters(for: config.model)
        for (key, value) in modelExtras {
            body[key] = value
        }

        for (key, value) in config.extraParameters {
            body[key] = value
        }

        if let tokens = config.maxTokens {
            if SettingsStore.shared.isReasoningModel(config.model) {
                body["max_completion_tokens"] = tokens
            } else {
                body["max_tokens"] = tokens
            }
        }

        return body
    }

    private func buildResponsesBody(_ config: Config) -> [String: Any] {
        let (instructions, input) = self.convertMessagesToResponsesInput(config.messages)

        var body: [String: Any] = [
            "model": config.model,
            "input": input,
        ]

        if let instructions {
            body["instructions"] = instructions
        }

        if let temp = config.temperature {
            body["temperature"] = temp
        }

        if !config.tools.isEmpty {
            body["tools"] = self.normalizeToolsForResponses(config.tools)
            body["tool_choice"] = "auto"
        }

        if config.streaming {
            body["stream"] = true
        }

        let modelExtras = ThinkingParserFactory.getExtraParameters(for: config.model)
        for (key, value) in modelExtras {
            self.applyResponsesExtraParameter(key: key, value: value, body: &body)
        }

        for (key, value) in config.extraParameters {
            self.applyResponsesExtraParameter(key: key, value: value, body: &body)
        }

        if let tokens = config.maxTokens {
            body["max_output_tokens"] = tokens
        }

        return body
    }

    private func buildAnthropicMessagesBody(_ config: Config) -> [String: Any] {
        let (system, messages) = self.convertMessagesToAnthropicInput(config.messages)

        var body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "max_tokens": max(1, config.maxTokens ?? 2048),
        ]

        if let system, !system.isEmpty {
            body["system"] = system
        }

        if let temperature = config.temperature {
            body["temperature"] = temperature
        }

        if !config.tools.isEmpty {
            body["tools"] = self.normalizeToolsForAnthropic(config.tools)
            body["tool_choice"] = ["type": "auto"]
        }

        if config.streaming {
            body["stream"] = true
        }

        let modelExtras = ThinkingParserFactory.getExtraParameters(for: config.model)
        for (key, value) in modelExtras {
            self.applyAnthropicExtraParameter(key: key, value: value, body: &body)
        }

        for (key, value) in config.extraParameters {
            self.applyAnthropicExtraParameter(key: key, value: value, body: &body)
        }

        return body
    }

    private func convertMessagesToAnthropicInput(_ messages: [[String: Any]]) -> (String?, [[String: Any]]) {
        var systemParts: [String] = []
        var outputMessages: [[String: Any]] = []

        for message in messages {
            let role = (message["role"] as? String ?? "user").lowercased()

            switch role {
            case "system":
                let text = self.extractStringContent(from: message)
                if !text.isEmpty {
                    systemParts.append(text)
                }

            case "tool":
                let toolUseID = message["tool_call_id"] as? String ?? "tool_\(UUID().uuidString.prefix(8))"
                var toolResult: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": toolUseID,
                ]

                if let contentBlocks = message["content"] as? [[String: Any]], !contentBlocks.isEmpty {
                    toolResult["content"] = contentBlocks
                } else {
                    let text = self.extractStringContent(from: message)
                    if !text.isEmpty {
                        toolResult["content"] = text
                    }
                }

                if let isError = message["is_error"] as? Bool {
                    toolResult["is_error"] = isError
                }

                outputMessages.append([
                    "role": "user",
                    "content": [toolResult],
                ])

            case "assistant":
                let text = self.extractStringContent(from: message)
                let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                var contentBlocks: [[String: Any]] = []

                if !trimmedText.isEmpty {
                    contentBlocks.append([
                        "type": "text",
                        "text": trimmedText,
                    ])
                }

                if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                    for toolCall in toolCalls {
                        let function = toolCall["function"] as? [String: Any]
                        let name = function?["name"] as? String ?? toolCall["name"] as? String
                        guard let toolName = name else { continue }

                        let callID = toolCall["id"] as? String ?? "tool_\(UUID().uuidString.prefix(8))"
                        let argumentsString = function?["arguments"] as? String ?? toolCall["arguments"] as? String ?? "{}"

                        let input: [String: Any]
                        if let data = argumentsString.data(using: .utf8),
                           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        {
                            input = parsed
                        } else {
                            input = [:]
                        }

                        contentBlocks.append([
                            "type": "tool_use",
                            "id": callID,
                            "name": toolName,
                            "input": input,
                        ])
                    }
                }

                if contentBlocks.isEmpty,
                   let blocks = message["content"] as? [[String: Any]],
                   !blocks.isEmpty
                {
                    outputMessages.append([
                        "role": "assistant",
                        "content": blocks,
                    ])
                } else if contentBlocks.isEmpty {
                    continue
                } else {
                    outputMessages.append([
                        "role": "assistant",
                        "content": contentBlocks,
                    ])
                }

            default:
                if let blocks = message["content"] as? [[String: Any]], !blocks.isEmpty {
                    outputMessages.append([
                        "role": "user",
                        "content": blocks,
                    ])
                } else {
                    outputMessages.append([
                        "role": "user",
                        "content": self.extractStringContent(from: message),
                    ])
                }
            }
        }

        let mergedSystem = systemParts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        return (mergedSystem.isEmpty ? nil : mergedSystem, outputMessages)
    }

    private func convertMessagesToResponsesInput(_ messages: [[String: Any]]) -> (String?, [[String: Any]]) {
        var instructions: [String] = []
        var input: [[String: Any]] = []

        for message in messages {
            let role = message["role"] as? String ?? "user"
            let content = message["content"] as? String ?? ""

            if role == "system" {
                if !content.isEmpty {
                    instructions.append(content)
                }
                continue
            }

            if role == "tool" {
                let callId = message["tool_call_id"] as? String ?? "call_unknown"
                input.append([
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": content,
                ])
                continue
            }

            if role == "assistant",
               let toolCalls = message["tool_calls"] as? [[String: Any]],
               !toolCalls.isEmpty
            {
                for toolCall in toolCalls {
                    guard let function = toolCall["function"] as? [String: Any],
                          let name = function["name"] as? String
                    else {
                        continue
                    }

                    input.append([
                        "type": "function_call",
                        "call_id": toolCall["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))",
                        "name": name,
                        "arguments": function["arguments"] as? String ?? "{}",
                    ])
                }

                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    input.append([
                        "role": "assistant",
                        "content": trimmed,
                    ])
                }
                continue
            }

            input.append([
                "role": role,
                "content": content,
            ])
        }

        let mergedInstructions = instructions.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (mergedInstructions.isEmpty ? nil : mergedInstructions, input)
    }

    private func normalizeToolsForResponses(_ tools: [[String: Any]]) -> [[String: Any]] {
        return tools.map { tool in
            guard (tool["type"] as? String) == "function",
                  let function = tool["function"] as? [String: Any],
                  let name = function["name"] as? String
            else {
                return tool
            }

            var normalized: [String: Any] = [
                "type": "function",
                "name": name,
            ]

            if let description = function["description"] {
                normalized["description"] = description
            }
            if let parameters = function["parameters"] {
                normalized["parameters"] = parameters
            }
            if let strict = function["strict"] ?? tool["strict"] {
                normalized["strict"] = strict
            }

            return normalized
        }
    }

    private func normalizeToolsForChatCompletions(_ tools: [[String: Any]]) -> [[String: Any]] {
        return tools.map { tool in
            guard (tool["type"] as? String) == "function",
                  tool["function"] == nil,
                  let name = tool["name"] as? String
            else {
                return tool
            }

            var function: [String: Any] = [
                "name": name,
            ]

            if let description = tool["description"] {
                function["description"] = description
            }
            if let parameters = tool["parameters"] {
                function["parameters"] = parameters
            }
            if let strict = tool["strict"] {
                function["strict"] = strict
            }

            return [
                "type": "function",
                "function": function,
            ]
        }
    }

    private func normalizeToolsForAnthropic(_ tools: [[String: Any]]) -> [[String: Any]] {
        return tools.compactMap { tool in
            let function = tool["function"] as? [String: Any]
            let name = function?["name"] as? String ?? tool["name"] as? String
            guard let toolName = name, !toolName.isEmpty else { return nil }

            let description = function?["description"] as? String ?? tool["description"] as? String
            var inputSchema = function?["parameters"] as? [String: Any] ??
                tool["parameters"] as? [String: Any] ??
                tool["input_schema"] as? [String: Any] ?? [:]

            if inputSchema["type"] == nil {
                inputSchema["type"] = "object"
            }
            if inputSchema["properties"] == nil {
                inputSchema["properties"] = [:]
            }

            var normalized: [String: Any] = [
                "name": toolName,
                "input_schema": inputSchema,
            ]

            if let description, !description.isEmpty {
                normalized["description"] = description
            }

            if let strict = function?["strict"] ?? tool["strict"] {
                normalized["strict"] = strict
            }

            if let inputExamples = function?["input_examples"] ?? tool["input_examples"] {
                normalized["input_examples"] = inputExamples
            }

            if let cacheControl = tool["cache_control"] {
                normalized["cache_control"] = cacheControl
            }

            return normalized
        }
    }

    private func applyResponsesExtraParameter(key: String, value: Any, body: inout [String: Any]) {
        switch key {
        case "reasoning_effort":
            var reasoning = body["reasoning"] as? [String: Any] ?? [:]
            reasoning["effort"] = value
            body["reasoning"] = reasoning
        default:
            body[key] = value
        }
    }

    private func applyAnthropicExtraParameter(key: String, value: Any, body: inout [String: Any]) {
        switch key {
        case "reasoning_effort", "enable_thinking", "max_output_tokens", "max_completion_tokens":
            // OpenAI-compatible parameters are ignored on Anthropic payloads.
            return
        default:
            body[key] = value
        }
    }

    private func extractStringContent(from message: [String: Any]) -> String {
        if let text = message["content"] as? String {
            return text
        }

        guard let blocks = message["content"] as? [[String: Any]] else {
            return ""
        }

        return blocks.compactMap { block in
            let type = (block["type"] as? String ?? "").lowercased()
            if type == "text" {
                return block["text"] as? String
            }
            return nil
        }.joined()
    }

    // MARK: - Non-Streaming Response

    private func processNonStreaming(request: URLRequest, format: APIFormat) async throws -> Response {
        DebugLogger.shared.debug("LLMClient: Making non-streaming request to \(request.url?.absoluteString ?? "unknown")", source: "LLMClient")

        let (data, response) = try await self.session.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let errText = String(data: data, encoding: .utf8) ?? "Unknown error"
            DebugLogger.shared.error("LLMClient: HTTP error \(http.statusCode): \(errText.prefix(200))", source: "LLMClient")
            throw LLMError.httpError(http.statusCode, errText)
        }

        DebugLogger.shared.debug("LLMClient: Non-streaming response received (\(data.count) bytes)", source: "LLMClient")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.invalidResponse
        }

        if format == .anthropicMessages {
            return self.parseAnthropicResponse(json)
        }

        if format == .responses {
            if let choices = json["choices"] as? [[String: Any]],
               let choice = choices.first,
               let message = choice["message"] as? [String: Any]
            {
                return self.parseMessageResponse(message)
            }

            guard json["output"] != nil || json["output_text"] != nil else {
                throw LLMError.invalidResponse
            }

            return self.parseResponsesResponse(json)
        }

        guard let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any]
        else {
            throw LLMError.invalidResponse
        }

        return self.parseMessageResponse(message)
    }

    private func processStreaming(request: URLRequest, format: APIFormat, config: Config) async throws -> Response {
        DebugLogger.shared.debug("LLMClient: Starting streaming request to \(request.url?.absoluteString ?? "unknown")", source: "LLMClient")

        let (bytes, response) = try await self.session.bytes(for: request)

        // Check for HTTP errors
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            let errText = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw LLMError.httpError(http.statusCode, errText)
        }

        // Create the appropriate parser for this model.
        // Anthropic streams thinking and text in separate content blocks, so we always use separate-field parsing there.
        var parser: ThinkingParser = ThinkingParserFactory.createParser(for: config.model)

        // Streaming state
        var state = ThinkingParserState.initial
        var thinkingBuffer: [String] = []
        var contentBuffer: [String] = []
        var tagDetectionBuffer = ""

        let isResponses = format == .responses
        let isAnthropic = format == .anthropicMessages

        if isAnthropic {
            parser = SeparateFieldThinkingParser()
        }

        // Tool call accumulation (supports multiple tool calls in one streamed response)
        struct StreamingToolAccumulator {
            var id: String?
            var name: String?
            var arguments: String = ""
        }
        var toolCallAccumulators: [String: StreamingToolAccumulator] = [:]
        var sawOutputTextDelta = false
        var anthropicToolIndexToID: [Int: String] = [:]
        var responsesOutputIndexToAccumulatorKey: [Int: String] = [:]

        func processContentChunk(_ content: String) {
            let containsThinkTag = content.contains("<think") || content.contains("</think") || content.contains("<thinking") || content.contains("</thinking")
            if thinkingBuffer.count + contentBuffer.count < 8 || containsThinkTag {
                let escaped = content.replacingOccurrences(of: "\n", with: "\\n")
                let marker = containsThinkTag ? " [HAS THINK TAG!]" : ""
                DebugLogger.shared.debug("LLMClient: Chunk '\(escaped)'\(marker)", source: "LLMClient")
            }

            let previousState = state
            let (newState, thinkChunk, contentChunk) = parser.processChunk(
                content,
                currentState: state,
                tagBuffer: &tagDetectionBuffer
            )

            if previousState != .inThinking && newState == .inThinking {
                DebugLogger.shared.debug("LLMClient: State transition → inThinking", source: "LLMClient")
                config.onThinkingStart?()
            }
            if previousState == .inThinking && newState == .inContent {
                DebugLogger.shared.debug("LLMClient: State transition → inContent", source: "LLMClient")
                config.onThinkingEnd?()
            }
            state = newState

            if !thinkChunk.isEmpty {
                thinkingBuffer.append(thinkChunk)
                config.onThinkingChunk?(thinkChunk)
            }
            if !contentChunk.isEmpty {
                contentBuffer.append(contentChunk)
                config.onContentChunk?(contentChunk)
            }
        }

        func processReasoningChunk(_ chunk: String) {
            if state == .initial {
                state = .inThinking
                config.onThinkingStart?()
            }
            thinkingBuffer.append(chunk)
            config.onThinkingChunk?(chunk)
        }

        // Process SSE lines
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }

            var jsonString = String(line.dropFirst(5))
            if jsonString.hasPrefix(" ") {
                jsonString = String(jsonString.dropFirst(1))
            }

            if jsonString.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                continue
            }

            guard let jsonData = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else {
                continue
            }

            if isAnthropic {
                let eventType = json["type"] as? String ?? ""

                if eventType == "error",
                   let errorObject = json["error"] as? [String: Any],
                   let message = errorObject["message"] as? String
                {
                    throw LLMError.httpError(500, message)
                }

                switch eventType {
                case "content_block_start":
                    guard let index = json["index"] as? Int,
                          let contentBlock = json["content_block"] as? [String: Any]
                    else { continue }

                    let blockType = contentBlock["type"] as? String ?? ""

                    if blockType == "tool_use" {
                        let id = contentBlock["id"] as? String ?? "tool_\(UUID().uuidString.prefix(8))"
                        let name = contentBlock["name"] as? String
                        var accumulator = toolCallAccumulators[id] ?? StreamingToolAccumulator()
                        accumulator.id = id

                        if let name {
                            if accumulator.name == nil {
                                config.onToolCallStart?(name)
                            }
                            accumulator.name = name
                        }

                        if let input = contentBlock["input"] as? [String: Any],
                           !input.isEmpty,
                           let inputData = try? JSONSerialization.data(withJSONObject: input, options: []),
                           let inputJSON = String(data: inputData, encoding: .utf8)
                        {
                            accumulator.arguments = inputJSON
                        }

                        toolCallAccumulators[id] = accumulator
                        anthropicToolIndexToID[index] = id
                    }

                case "content_block_delta":
                    guard let delta = json["delta"] as? [String: Any] else { continue }
                    let deltaType = delta["type"] as? String ?? ""

                    switch deltaType {
                    case "text_delta":
                        if let text = delta["text"] as? String {
                            processContentChunk(text)
                        }

                    case "thinking_delta":
                        if let thinking = delta["thinking"] as? String {
                            processReasoningChunk(thinking)
                        }

                    case "input_json_delta":
                        guard let index = json["index"] as? Int else { continue }
                        let toolID = anthropicToolIndexToID[index] ?? "index_\(index)"
                        var accumulator = toolCallAccumulators[toolID] ?? StreamingToolAccumulator()
                        accumulator.id = accumulator.id ?? toolID

                        if let partialJSON = delta["partial_json"] as? String {
                            accumulator.arguments += partialJSON
                        }

                        toolCallAccumulators[toolID] = accumulator

                    default:
                        break
                    }

                default:
                    break
                }

                continue
            }

            if isResponses {
                let eventType = json["type"] as? String ?? ""

                if eventType.isEmpty, json["choices"] != nil {
                    // Some chat-only providers answer a Responses-shaped request with
                    // chat-completions SSE. Let the shared chat parser below handle it.
                } else {
                    switch eventType {
                    case "response.output_text.delta":
                        if let delta = json["delta"] as? String {
                            sawOutputTextDelta = true
                            processContentChunk(delta)
                        }

                    case "response.output_text.done":
                        if !sawOutputTextDelta, let text = json["text"] as? String {
                            processContentChunk(text)
                        }

                    case "response.function_call_arguments.delta", "response.function_call_arguments.done":
                        let outputIndex = json["output_index"] as? Int
                        let accumulatorKey: String
                        if let itemID = json["item_id"] as? String {
                            accumulatorKey = itemID
                            if let outputIndex {
                                responsesOutputIndexToAccumulatorKey[outputIndex] = itemID
                            }
                        } else if let outputIndex,
                                  let knownKey = responsesOutputIndexToAccumulatorKey[outputIndex]
                        {
                            accumulatorKey = knownKey
                        } else {
                            accumulatorKey = "index_\(outputIndex ?? 0)"
                        }

                        var accumulator = toolCallAccumulators[accumulatorKey] ?? StreamingToolAccumulator()

                        if let delta = json["delta"] as? String {
                            accumulator.arguments += delta
                        }
                        if let arguments = json["arguments"] as? String {
                            accumulator.arguments = arguments
                        }

                        toolCallAccumulators[accumulatorKey] = accumulator

                    case "response.output_item.added", "response.output_item.done":
                        guard let item = json["item"] as? [String: Any] else { continue }

                        if (item["type"] as? String) == "function_call" {
                            let outputIndex = json["output_index"] as? Int
                            let fallbackIndexKey = "index_\(outputIndex ?? 0)"
                            let accumulatorKey =
                                item["id"] as? String ?? json["item_id"] as? String
                                    ?? (outputIndex.map { "index_\($0)" })
                                    ?? item["call_id"] as? String
                                    ?? "call_\(UUID().uuidString.prefix(8))"
                            let callID = item["call_id"] as? String ?? accumulatorKey

                            if let outputIndex {
                                responsesOutputIndexToAccumulatorKey[outputIndex] = accumulatorKey
                            }

                            if accumulatorKey != fallbackIndexKey,
                               toolCallAccumulators[accumulatorKey] == nil,
                               let existingAccumulator = toolCallAccumulators.removeValue(forKey: fallbackIndexKey)
                            {
                                toolCallAccumulators[accumulatorKey] = existingAccumulator
                            }

                            var accumulator =
                                toolCallAccumulators[accumulatorKey] ?? StreamingToolAccumulator()
                            accumulator.id = callID
                            if let name = item["name"] as? String {
                                if accumulator.name == nil {
                                    config.onToolCallStart?(name)
                                }
                                accumulator.name = name
                            }
                            if let arguments = item["arguments"] as? String {
                                accumulator.arguments = arguments
                            }
                            toolCallAccumulators[accumulatorKey] = accumulator
                        } else if (item["type"] as? String) == "reasoning" {
                            if let summary = item["summary"] as? String, !summary.isEmpty {
                                processReasoningChunk(summary)
                            } else if let summaryItems = item["summary"] as? [[String: Any]] {
                                for summaryItem in summaryItems {
                                    if let text = summaryItem["text"] as? String, !text.isEmpty {
                                        processReasoningChunk(text)
                                    }
                                }
                            }
                        }

                    default:
                        if eventType.contains("reasoning") {
                            if let delta = json["delta"] as? String, !delta.isEmpty {
                                processReasoningChunk(delta)
                            }
                            if let text = json["text"] as? String, !text.isEmpty {
                                processReasoningChunk(text)
                            }
                        }
                    }

                    continue
                }
            }

            guard let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any]
            else {
                continue
            }

            // DEBUG LOG: Show full delta to see all fields (e.g., 'reasoning', 'thought', 'delta_reasoning', etc.)
            if let deltaData = try? JSONSerialization.data(withJSONObject: delta, options: [.fragmentsAllowed]),
               let deltaString = String(data: deltaData, encoding: .utf8)
            {
                DebugLogger.shared.debug("LLMClient: Full Delta: \(deltaString)", source: "LLMClient")
            }

            // Handle separate reasoning fields (OpenAI 'reasoning', 'reasoning_content', DeepSeek, etc.)
            let reasoningField = delta["reasoning_content"] as? String ??
                delta["reasoning"] as? String ??
                delta["thought"] as? String ??
                delta["thinking"] as? String

            if let reasoning = reasoningField {
                processReasoningChunk(reasoning)
            }

            // Handle content with potential <think> tags
            if let content = delta["content"] as? String {
                // If we were in thinking mode via a separate field (not tag-based),
                // receiving "content" usually means the thinking phase is over.
                if state == .inThinking && reasoningField == nil && tagDetectionBuffer.isEmpty {
                    // This is a subtle heuristic: if we were thinking, didn't just get a reasoning field chunk,
                    // and have no partial tags buffered, we should check if this content chunk
                    // is the start of the final answer.
                    // For safety with tag-based parsers, we let the parser decide unless it's a known separate-field model.
                }

                processContentChunk(content)
            }

            // Handle tool calls (streamed in parts, potentially multiple)
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for tc in toolCalls {
                    let index = tc["index"] as? Int ?? 0
                    let key = "index_\(index)"
                    var accumulator = toolCallAccumulators[key] ?? StreamingToolAccumulator()

                    if let id = tc["id"] as? String {
                        accumulator.id = id
                    }

                    if let function = tc["function"] as? [String: Any] {
                        if let name = function["name"] as? String {
                            accumulator.name = name
                            config.onToolCallStart?(name)
                        }
                        if let args = function["arguments"] as? String {
                            accumulator.arguments += args
                        }
                    }

                    toolCallAccumulators[key] = accumulator
                }
            }
        }

        // Finalize - flush any remaining content in tagDetectionBuffer
        if !tagDetectionBuffer.isEmpty {
            // Anything left in the buffer should go to the appropriate place
            if state == .inThinking {
                thinkingBuffer.append(tagDetectionBuffer)
                config.onThinkingChunk?(tagDetectionBuffer)
                DebugLogger.shared.debug("LLMClient: Flushing remaining tagBuffer to thinking (\(tagDetectionBuffer.count) chars)", source: "LLMClient")
            } else {
                contentBuffer.append(tagDetectionBuffer)
                config.onContentChunk?(tagDetectionBuffer)
                DebugLogger.shared.debug("LLMClient: Flushing remaining tagBuffer to content (\(tagDetectionBuffer.count) chars)", source: "LLMClient")
            }
        }

        // Use parser's finalize to get final clean thinking and content
        let (thinkingText, contentText) = parser.finalize(thinkingBuffer: thinkingBuffer, contentBuffer: contentBuffer, finalState: state)

        DebugLogger.shared.debug("LLMClient: Streaming complete. Thinking: \(thinkingText.count) chars, Content: \(contentText.count) chars", source: "LLMClient")

        // Build tool calls array
        var parsedToolCalls: [ToolCall] = []
        if !toolCallAccumulators.isEmpty {
            for key in toolCallAccumulators.keys.sorted() {
                guard let accumulator = toolCallAccumulators[key],
                      let name = accumulator.name
                else {
                    continue
                }

                let args: [String: Any]
                if accumulator.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    args = [:]
                } else if let argsData = accumulator.arguments.data(using: .utf8),
                          let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                {
                    args = parsed
                } else {
                    DebugLogger.shared.warning("LLMClient: Failed to parse streamed tool arguments for '\(name)'", source: "LLMClient")
                    args = [:]
                }

                parsedToolCalls.append(
                    ToolCall(
                        id: accumulator.id ?? "call_\(UUID().uuidString.prefix(8))",
                        name: name,
                        arguments: args
                    )
                )
                DebugLogger.shared.debug("LLMClient: Parsed tool call [\(key)]: \(name)", source: "LLMClient")
            }
        }

        DebugLogger.shared.debug("LLMClient: Returning response. Content length: \(contentText.count), Has thinking: \(thinkingText.isEmpty ? "No" : "Yes (\(thinkingText.count) chars)")", source: "LLMClient")

        return Response(
            thinking: thinkingText.isEmpty ? nil : thinkingText,
            content: contentText,
            toolCalls: parsedToolCalls
        )
    }

    private func parseResponsesResponse(_ json: [String: Any]) -> Response {
        var contentParts: [String] = []
        var thinkingParts: [String] = []
        var toolCalls: [ToolCall] = []

        if let output = json["output"] as? [[String: Any]] {
            for item in output {
                let type = item["type"] as? String ?? ""

                if type == "message" {
                    contentParts.append(contentsOf: self.extractTextParts(from: item))
                    continue
                }

                if type == "function_call", let toolCall = self.parseResponsesToolCall(item) {
                    toolCalls.append(toolCall)
                    continue
                }

                if type == "reasoning" {
                    if let summary = item["summary"] as? String, !summary.isEmpty {
                        thinkingParts.append(summary)
                    } else if let summaryItems = item["summary"] as? [[String: Any]] {
                        for summaryItem in summaryItems {
                            if let text = summaryItem["text"] as? String, !text.isEmpty {
                                thinkingParts.append(text)
                            }
                        }
                    }
                }
            }
        }

        if contentParts.isEmpty, let outputText = json["output_text"] as? String, !outputText.isEmpty {
            contentParts.append(outputText)
        }

        let rawContent = contentParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let (tagThinking, cleanedContent) = self.stripThinkingTags(rawContent)
        let allThinking = (thinkingParts + [tagThinking]).filter { !$0.isEmpty }.joined(separator: "\n")

        return Response(
            thinking: allThinking.isEmpty ? nil : allThinking,
            content: cleanedContent.isEmpty ? rawContent : cleanedContent,
            toolCalls: toolCalls
        )
    }

    private func parseAnthropicResponse(_ json: [String: Any]) -> Response {
        var contentParts: [String] = []
        var thinkingParts: [String] = []
        var toolCalls: [ToolCall] = []

        if let contentBlocks = json["content"] as? [[String: Any]] {
            for block in contentBlocks {
                let type = block["type"] as? String ?? ""

                switch type {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty {
                        contentParts.append(text)
                    }

                case "thinking":
                    if let thinking = block["thinking"] as? String, !thinking.isEmpty {
                        thinkingParts.append(thinking)
                    }

                case "redacted_thinking":
                    if let redacted = block["data"] as? String, !redacted.isEmpty {
                        thinkingParts.append(redacted)
                    }

                case "tool_use":
                    if let toolCall = self.parseAnthropicToolUse(block) {
                        toolCalls.append(toolCall)
                    }

                default:
                    break
                }
            }
        }

        let content = contentParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let thinking = thinkingParts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return Response(
            thinking: thinking.isEmpty ? nil : thinking,
            content: content,
            toolCalls: toolCalls
        )
    }

    private func parseAnthropicToolUse(_ block: [String: Any]) -> ToolCall? {
        guard let name = block["name"] as? String else {
            return nil
        }

        let id = block["id"] as? String ?? "tool_\(UUID().uuidString.prefix(8))"

        if let input = block["input"] as? [String: Any] {
            return ToolCall(id: id, name: name, arguments: input)
        }

        if let inputString = block["input"] as? String,
           let data = inputString.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            return ToolCall(id: id, name: name, arguments: parsed)
        }

        return ToolCall(id: id, name: name, arguments: [:])
    }

    private func extractTextParts(from messageItem: [String: Any]) -> [String] {
        if let text = messageItem["content"] as? String {
            return text.isEmpty ? [] : [text]
        }

        guard let contentItems = messageItem["content"] as? [[String: Any]] else {
            return []
        }

        var parts: [String] = []
        for contentItem in contentItems {
            if let text = contentItem["text"] as? String, !text.isEmpty {
                parts.append(text)
            }
        }
        return parts
    }

    private func parseResponsesToolCall(_ item: [String: Any]) -> ToolCall? {
        guard let name = item["name"] as? String else {
            return nil
        }

        let id = item["call_id"] as? String ?? item["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))"
        let argumentsString = item["arguments"] as? String ?? "{}"

        let args: [String: Any]
        if argumentsString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args = [:]
        } else if let argsData = argumentsString.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
        {
            args = parsed
        } else {
            args = [:]
        }

        return ToolCall(id: id, name: name, arguments: args)
    }

    // MARK: - Parse Non-Streaming Message

    private func parseMessageResponse(_ message: [String: Any]) -> Response {
        // Extract content
        let rawContent = message["content"] as? String ?? ""

        // Check for tool calls
        var parsedToolCalls: [ToolCall] = []
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            parsedToolCalls = toolCalls.compactMap { tc -> ToolCall? in
                guard let function = tc["function"] as? [String: Any],
                      let name = function["name"] as? String
                else {
                    return nil
                }

                let argsString = function["arguments"] as? String ?? "{}"
                let args: [String: Any]
                if argsString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    args = [:]
                } else if let argsData = argsString.data(using: .utf8),
                          let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                {
                    args = parsed
                } else {
                    args = [:]
                }

                let id = tc["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))"
                return ToolCall(id: id, name: name, arguments: args)
            }
            // Empty tool calls are fine, no action needed
        }

        // Strip thinking tags and extract thinking content
        let (thinking, cleanedContent) = self.stripThinkingTags(rawContent)

        // Also check for multiple reasoning field variants
        let reasoningContent = message["reasoning_content"] as? String ??
            message["reasoning"] as? String ??
            message["thought"] as? String ??
            message["thinking"] as? String

        let finalThinking = [thinking, reasoningContent].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")

        return Response(
            thinking: finalThinking.isEmpty ? nil : finalThinking,
            content: cleanedContent.isEmpty ? rawContent : cleanedContent,
            toolCalls: parsedToolCalls
        )
    }

    // MARK: - Thinking Token Extraction

    /// Pattern matches both <think>...</think> and <thinking>...</thinking> including multiline
    private static let thinkingTagPattern = #"<think(?:ing)?>([\s\S]*?)</think(?:ing)?>"#

    /// Pattern for orphan closing tags with content before them (no opening tag)
    private static let orphanThinkingPattern = #"^([\s\S]*?)</think(?:ing)?>"#

    /// Strips thinking tags from text and returns (thinking, cleanedContent)
    func stripThinkingTags(_ text: String) -> (thinking: String, content: String) {
        var workingText = text
        var thinking = ""

        // First, handle proper <think>...</think> pairs
        if let regex = try? NSRegularExpression(pattern: Self.thinkingTagPattern, options: []) {
            let range = NSRange(workingText.startIndex..., in: workingText)
            let matches = regex.matches(in: workingText, options: [], range: range)

            for match in matches {
                if let thinkRange = Range(match.range(at: 1), in: workingText) {
                    thinking += String(workingText[thinkRange])
                }
            }

            workingText = regex.stringByReplacingMatches(in: workingText, options: [], range: range, withTemplate: "")
        }

        // Second, handle orphan closing tags (content before </think> without opening tag)
        // This handles cases like "We have a request...</think>Hello!"
        if let orphanRegex = try? NSRegularExpression(pattern: Self.orphanThinkingPattern, options: []) {
            let range = NSRange(workingText.startIndex..., in: workingText)
            let matches = orphanRegex.matches(in: workingText, options: [], range: range)

            for match in matches {
                if let thinkRange = Range(match.range(at: 1), in: workingText) {
                    thinking += String(workingText[thinkRange])
                }
            }

            workingText = orphanRegex.stringByReplacingMatches(in: workingText, options: [], range: range, withTemplate: "")
        }

        // Also remove any stray </think> or </thinking> tags that might remain
        workingText = workingText.replacingOccurrences(of: "</think>", with: "")
        workingText = workingText.replacingOccurrences(of: "</thinking>", with: "")
        workingText = workingText.replacingOccurrences(of: "<think>", with: "")
        workingText = workingText.replacingOccurrences(of: "<thinking>", with: "")

        let cleaned = workingText.trimmingCharacters(in: .whitespacesAndNewlines)

        return (thinking, cleaned)
    }

    // MARK: - Helper Methods

    /// Check if an error is retryable (transient network issues)
    private func isRetryableError(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet,
             .timedOut,
             .networkConnectionLost,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private func shouldFallbackToChat(statusCode: Int, message: String) -> Bool {
        if statusCode == 404 || statusCode == 405 {
            return true
        }

        if statusCode == 400 {
            let lowered = message.lowercased()
            if lowered.contains("unknown") && lowered.contains("input") {
                return true
            }
            if lowered.contains("unknown") && lowered.contains("responses") {
                return true
            }
            if lowered.contains("not supported") && lowered.contains("responses") {
                return true
            }
        }

        return false
    }

    /// Check if a URL is a local/private endpoint
    private func isLocalEndpoint(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let host = url.host else { return false }

        let hostLower = host.lowercased()

        // Localhost
        if hostLower == "localhost" || hostLower == "127.0.0.1" {
            return true
        }

        // 127.x.x.x
        if hostLower.hasPrefix("127.") {
            return true
        }

        // 10.x.x.x (Private Class A)
        if hostLower.hasPrefix("10.") {
            return true
        }

        // 192.168.x.x (Private Class C)
        if hostLower.hasPrefix("192.168.") {
            return true
        }

        // 172.16.x.x - 172.31.x.x (Private Class B)
        if hostLower.hasPrefix("172.") {
            let components = hostLower.split(separator: ".")
            if components.count >= 2,
               let secondOctet = Int(components[1]),
               secondOctet >= 16 && secondOctet <= 31
            {
                return true
            }
        }

        return false
    }

    // MARK: - Logging Helpers

    private func logRequest(_ request: URLRequest) {
        guard let url = request.url, let method = request.httpMethod else { return }

        var bodyString = ""
        if let body = request.httpBody {
            bodyString = String(data: body, encoding: .utf8) ?? ""
        }

        var curl = "curl -X \(method) \"\(url.absoluteString)\" \\\n"
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            let loweredKey = key.lowercased()
            let shouldMask = loweredKey.contains("auth") || loweredKey.contains("api-key")
            let maskedValue = shouldMask ? "[REDACTED]" : value
            curl += "  -H \"\(key): \(maskedValue)\" \\\n"
        }
        curl += "  -d '\(bodyString)'"

        DebugLogger.shared.info("LLMClient: Full Request as cURL:\n\(curl)", source: "LLMClient")
    }
}
