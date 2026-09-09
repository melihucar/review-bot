import Foundation

// MARK: - Wire types

/// A minimal encodable JSON tree, used to declare tool parameter schemas.
indirect enum JSONValue: Encodable {
    case string(String)
    case integer(Int)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .array(values): try container.encode(values)
        case let .object(values): try container.encode(values)
        }
    }
}

struct ChatToolCall: Codable, Equatable {
    struct Function: Codable, Equatable {
        let name: String
        /// A JSON object, as a string — the provider does not guarantee it parses.
        let arguments: String
    }

    let id: String
    let type: String
    let function: Function

    init(id: String, type: String = "function", function: Function) {
        self.id = id
        self.type = type
        self.function = function
    }
}

struct ChatMessage: Codable, Equatable {
    enum Role: String, Codable {
        case system
        case user
        case assistant
        case tool
    }

    var role: Role
    var content: String?
    var toolCalls: [ChatToolCall]?
    var toolCallID: String?

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    static func system(_ text: String) -> ChatMessage { ChatMessage(role: .system, content: text) }
    static func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, content: text) }

    static func toolResult(_ text: String, callID: String) -> ChatMessage {
        ChatMessage(role: .tool, content: text, toolCallID: callID)
    }

    init(
        role: Role,
        content: String? = nil,
        toolCalls: [ChatToolCall]? = nil,
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

struct ChatTool: Encodable {
    struct Function: Encodable {
        let name: String
        let description: String
        let parameters: JSONValue
    }

    let type = "function"
    let function: Function
}

struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let tools: [ChatTool]?
    let stream = false
}

// MARK: - Client

enum ChatCompletionError: LocalizedError {
    case http(status: Int, message: String)
    case toolsUnsupported(model: String)
    case emptyResponse
    case malformedResponse(String)
    /// The provider stopped responding, or the review ran past its wall-clock budget.
    ///
    /// This exists because DeepSeek is not a child process: the CLI reviewers get a hard bound
    /// from `ProcessRunner`'s `perl alarm` and surface `CommandExecutionError.timedOut`, which
    /// is what tells `ReviewerResult.timedOut` not to retry a hung reviewer inside the same
    /// review. Without an equivalent signal here, a DeepSeek timeout looks like any other
    /// failure and earns a second full agent loop against a provider that is still not
    /// answering — paid twice, for the same silence.
    case timedOut(seconds: Int)

    var errorDescription: String? {
        switch self {
        case let .http(status, message):
            "DeepSeek returned HTTP \(status): \(message)"
        case let .toolsUnsupported(model):
            "The model \(model) rejected tool calls."
        case .emptyResponse:
            "DeepSeek returned no message content."
        case let .malformedResponse(detail):
            "Could not read DeepSeek's response: \(detail)"
        case let .timedOut(seconds):
            "DeepSeek did not answer within \(seconds)s."
        }
    }
}

/// One completion: the reply, plus what it consumed when the provider says.
struct ChatCompletionResult {
    let message: ChatMessage
    /// `nil` when the response carried no `usage` object.
    let usage: TokenUsage?

    init(message: ChatMessage, usage: TokenUsage? = nil) {
        self.message = message
        self.usage = usage
    }
}

/// The seam that lets the review workflow be tested without reaching DeepSeek.
protocol ChatCompleting: Sendable {
    func complete(
        _ request: ChatCompletionRequest,
        apiKey: String
    ) async throws -> ChatCompletionResult
}

struct DeepSeekClient: ChatCompleting {
    private let baseURL: URL
    private let session: URLSession
    private let maxAttempts: Int

    init(
        baseURL: URL = URL(string: "https://api.deepseek.com")!,
        session: URLSession? = nil,
        maxAttempts: Int = 3
    ) {
        self.baseURL = baseURL
        self.maxAttempts = max(1, maxAttempts)
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 180
            configuration.timeoutIntervalForResource = 900
            self.session = URLSession(configuration: configuration)
        }
    }

    func complete(
        _ request: ChatCompletionRequest,
        apiKey: String
    ) async throws -> ChatCompletionResult {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                return try await send(request, apiKey: apiKey)
            } catch let error as ChatCompletionError {
                // A model that cannot use tools will keep rejecting them; let the caller retry
                // without them instead of burning attempts here.
                if case .toolsUnsupported = error { throw error }
                if case let .http(status, _) = error, status == 429 || status >= 500 {
                    lastError = error
                } else {
                    throw error
                }
            } catch let error as URLError where error.code == .timedOut {
                // Deliberately not retried. A review is many calls, so waiting out this timeout
                // twice more here would spend three times the ceiling inside a single round of
                // an agent loop that has a dozen rounds left. Report it as a timeout instead and
                // let the engine decide, which is the same division of labour the CLI reviewers
                // already have with their process alarm.
                throw ChatCompletionError.timedOut(
                    seconds: Int(session.configuration.timeoutIntervalForRequest)
                )
            } catch {
                lastError = error
            }
            if attempt < maxAttempts {
                try? await Task.sleep(for: .seconds(2 << (attempt - 1)))
            }
        }
        throw lastError ?? ChatCompletionError.emptyResponse
    }

    private func send(
        _ request: ChatCompletionRequest,
        apiKey: String
    ) async throws -> ChatCompletionResult {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await session.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = errorMessage(from: data)
            // DeepSeek's reasoning models reject `tools` outright; surface that distinctly so
            // the reviewer can fall back to a single-shot review.
            if status == 400, request.tools != nil, mentionsTools(message) {
                throw ChatCompletionError.toolsUnsupported(model: request.model)
            }
            throw ChatCompletionError.http(status: status, message: message)
        }

        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw ChatCompletionError.malformedResponse(error.localizedDescription)
        }
        guard let message = decoded.choices.first?.message else {
            throw ChatCompletionError.emptyResponse
        }
        return ChatCompletionResult(message: message, usage: decoded.usage?.tokenUsage)
    }

    private func mentionsTools(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("tool") || lowered.contains("function call")
    }

    private func errorMessage(from data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           let message = envelope.error?.message {
            return message
        }
        let raw = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "no response body" : String(raw.prefix(400))
    }

    private struct ErrorEnvelope: Decodable {
        struct Payload: Decodable { let message: String? }
        let error: Payload?
    }
}

struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        let message: ChatMessage
    }

    /// DeepSeek reports tokens but never a price, so a review's cost stays unknown while its
    /// token counts do not. `prompt_tokens` *includes* the cached hits, so the uncached figure
    /// is the difference — counting both would report the same tokens twice.
    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        let promptCacheHitTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case promptCacheHitTokens = "prompt_cache_hit_tokens"
        }

        var tokenUsage: TokenUsage {
            let cached = max(0, promptCacheHitTokens ?? 0)
            let prompt = max(0, promptTokens ?? 0)
            return TokenUsage(
                inputTokens: max(0, prompt - cached),
                cachedInputTokens: cached,
                outputTokens: max(0, completionTokens ?? 0),
                requests: 1
            )
        }
    }

    let choices: [Choice]
    let usage: Usage?
}
