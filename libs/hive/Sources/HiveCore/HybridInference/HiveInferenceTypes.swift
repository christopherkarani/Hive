/// Canonical role for a chat message.
public enum HiveChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

/// Tool definition exposed to a model.
public struct HiveToolDefinition: Codable, Sendable {
    public let name: String
    public let description: String
    /// JSON Schema string (UTF-8) describing tool arguments.
    public let parametersJSONSchema: String

    public init(name: String, description: String, parametersJSONSchema: String) {
        self.name = name
        self.description = description
        self.parametersJSONSchema = parametersJSONSchema
    }
}

/// Tool invocation emitted by a model.
public struct HiveToolCall: Codable, Sendable {
    public let id: String
    public let name: String
    /// JSON string (UTF-8) containing tool arguments.
    public let argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// Result returned by a tool invocation.
public struct HiveToolResult: Codable, Sendable {
    public let toolCallID: String
    public let content: String

    public init(toolCallID: String, content: String) {
        self.toolCallID = toolCallID
        self.content = content
    }
}

/// Special operations used by message reducers.
public enum HiveChatMessageOp: String, Codable, Sendable {
    /// Remove the message with the matching ID.
    case remove
    /// Remove all messages (reset history at this marker).
    case removeAll
}

/// Canonical chat message.
public struct HiveChatMessage: Codable, Sendable {
    public let id: String
    public let role: HiveChatRole
    public let content: String
    public let name: String?
    public let toolCallID: String?
    public let toolCalls: [HiveToolCall]
    public let op: HiveChatMessageOp?

    public init(
        id: String,
        role: HiveChatRole,
        content: String,
        name: String? = nil,
        toolCallID: String? = nil,
        toolCalls: [HiveToolCall] = [],
        op: HiveChatMessageOp? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.name = name
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
        self.op = op
    }
}

/// Model request payload.
public struct HiveChatRequest: Codable, Sendable {
    public let model: String
    public let messages: [HiveChatMessage]
    public let tools: [HiveToolDefinition]

    public init(model: String, messages: [HiveChatMessage], tools: [HiveToolDefinition]) {
        self.model = model
        self.messages = messages
        self.tools = tools
    }
}

/// Model response payload.
public struct HiveChatResponse: Codable, Sendable {
    public let message: HiveChatMessage

    public init(message: HiveChatMessage) {
        self.message = message
    }
}

/// Streaming chunk emitted by a model client.
public enum HiveChatStreamChunk: Sendable {
    /// Incremental token content.
    case token(String)
    /// Final response for the stream; must be emitted exactly once and last on success.
    case final(HiveChatResponse)
}

/// Model client interface used by adapters.
///
/// - Important: If `stream(_:)` completes successfully, it must emit exactly one `.final` chunk and it must be last.
///              `complete(_:)` must return the same response that would be produced by the `.final` chunk.
public protocol HiveModelClient: Sendable {
    /// Returns the same response as the final stream chunk for the same request.
    func complete(_ request: HiveChatRequest) async throws -> HiveChatResponse
    /// Streams incremental tokens and ends with a single final response on success.
    func stream(_ request: HiveChatRequest) -> AsyncThrowingStream<HiveChatStreamChunk, Error>
}

/// Type-erased model client wrapper.
public struct AnyHiveModelClient: HiveModelClient, Sendable {
    private let _complete: @Sendable (HiveChatRequest) async throws -> HiveChatResponse
    private let _stream: @Sendable (HiveChatRequest) -> AsyncThrowingStream<HiveChatStreamChunk, Error>

    public init<M: HiveModelClient>(_ model: M) {
        self._complete = model.complete
        self._stream = model.stream
    }

    public func complete(_ request: HiveChatRequest) async throws -> HiveChatResponse {
        try await _complete(request)
    }

    public func stream(_ request: HiveChatRequest) -> AsyncThrowingStream<HiveChatStreamChunk, Error> {
        _stream(request)
    }
}

/// Tool registry interface for invocation.
public protocol HiveToolRegistry: Sendable {
    func listTools() -> [HiveToolDefinition]
    func invoke(_ call: HiveToolCall) async throws -> HiveToolResult
}

/// Type-erased tool registry wrapper.
public struct AnyHiveToolRegistry: HiveToolRegistry, Sendable {
    private let _listTools: @Sendable () -> [HiveToolDefinition]
    private let _invoke: @Sendable (HiveToolCall) async throws -> HiveToolResult

    public init<T: HiveToolRegistry>(_ tools: T) {
        self._listTools = tools.listTools
        self._invoke = tools.invoke
    }

    public func listTools() -> [HiveToolDefinition] { _listTools() }
    public func invoke(_ call: HiveToolCall) async throws -> HiveToolResult { try await _invoke(call) }
}

/// Routes model requests to a specific model client.
public protocol HiveModelRouter: Sendable {
    func route(_ request: HiveChatRequest, hints: HiveInferenceHints?) -> AnyHiveModelClient
}

/// Desired latency tier for inference.
public enum HiveLatencyTier: String, Sendable {
    case interactive
    case background
}

/// Network conditions relevant to inference.
public enum HiveNetworkState: String, Sendable {
    case offline
    case online
    case metered
}

/// Optional hints to guide model routing.
public struct HiveInferenceHints: Sendable {
    public let latencyTier: HiveLatencyTier
    public let privacyRequired: Bool
    public let tokenBudget: Int?
    public let networkState: HiveNetworkState

    public init(
        latencyTier: HiveLatencyTier,
        privacyRequired: Bool,
        tokenBudget: Int?,
        networkState: HiveNetworkState
    ) {
        self.latencyTier = latencyTier
        self.privacyRequired = privacyRequired
        self.tokenBudget = tokenBudget
        self.networkState = networkState
    }
}
