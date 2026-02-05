import Foundation

public struct ModelTurn<Schema: HiveSchema>: WorkflowComponent, Sendable {
    public enum Tools: Sendable {
        case none
        case environment
        case explicit([HiveToolDefinition])
    }

    public enum Mode: Sendable {
        case complete
        case agentLoop(HiveModelToolLoopConfiguration)
    }

    private let id: HiveNodeID
    private let modelName: String
    private let messageProvider: @Sendable (HiveStoreView<Schema>) throws -> [HiveChatMessage]
    private let toolsPolicy: Tools
    private let modeValue: Mode
    private let outputWrites: [@Sendable (HiveChatResponse) throws -> AnyHiveWrite<Schema>]
    private let messageWrites: [@Sendable ([HiveChatMessage]) throws -> AnyHiveWrite<Schema>]
    private let isStart: Bool

    public init(_ id: String, model: String, messages: [HiveChatMessage]) {
        self.init(
            id: HiveNodeID(id),
            modelName: model,
            messageProvider: { _ in messages },
            toolsPolicy: .none,
            modeValue: .complete,
            outputWrites: [],
            messageWrites: [],
            isStart: false
        )
    }

    public init(
        _ id: String,
        model: String,
        messages: @escaping @Sendable (HiveStoreView<Schema>) throws -> [HiveChatMessage]
    ) {
        self.init(
            id: HiveNodeID(id),
            modelName: model,
            messageProvider: messages,
            toolsPolicy: .none,
            modeValue: .complete,
            outputWrites: [],
            messageWrites: [],
            isStart: false
        )
    }

    private init(
        id: HiveNodeID,
        modelName: String,
        messageProvider: @escaping @Sendable (HiveStoreView<Schema>) throws -> [HiveChatMessage],
        toolsPolicy: Tools,
        modeValue: Mode,
        outputWrites: [@Sendable (HiveChatResponse) throws -> AnyHiveWrite<Schema>],
        messageWrites: [@Sendable ([HiveChatMessage]) throws -> AnyHiveWrite<Schema>],
        isStart: Bool
    ) {
        self.id = id
        self.modelName = modelName
        self.messageProvider = messageProvider
        self.toolsPolicy = toolsPolicy
        self.modeValue = modeValue
        self.outputWrites = outputWrites
        self.messageWrites = messageWrites
        self.isStart = isStart
    }

    public func start() -> ModelTurn<Schema> {
        ModelTurn(
            id: id,
            modelName: modelName,
            messageProvider: messageProvider,
            toolsPolicy: toolsPolicy,
            modeValue: modeValue,
            outputWrites: outputWrites,
            messageWrites: messageWrites,
            isStart: true
        )
    }

    public func tools(_ policy: Tools) -> ModelTurn<Schema> {
        ModelTurn(
            id: id,
            modelName: modelName,
            messageProvider: messageProvider,
            toolsPolicy: policy,
            modeValue: modeValue,
            outputWrites: outputWrites,
            messageWrites: messageWrites,
            isStart: isStart
        )
    }

    public func mode(_ mode: Mode) -> ModelTurn<Schema> {
        ModelTurn(
            id: id,
            modelName: modelName,
            messageProvider: messageProvider,
            toolsPolicy: toolsPolicy,
            modeValue: mode,
            outputWrites: outputWrites,
            messageWrites: messageWrites,
            isStart: isStart
        )
    }

    public func agentLoop(
        _ configuration: HiveModelToolLoopConfiguration = .init(
            modelCallMode: .complete,
            maxModelInvocations: 8,
            toolCallOrder: .asEmitted
        )
    ) -> ModelTurn<Schema> {
        mode(.agentLoop(configuration))
    }

    public func writes(to key: HiveChannelKey<Schema, String>) -> ModelTurn<Schema> {
        writes(to: key) { $0.message.content }
    }

    public func writes<Value: Sendable>(
        to key: HiveChannelKey<Schema, Value>,
        _ transform: @escaping @Sendable (HiveChatResponse) throws -> Value
    ) -> ModelTurn<Schema> {
        let write: @Sendable (HiveChatResponse) throws -> AnyHiveWrite<Schema> = { response in
            AnyHiveWrite(key, try transform(response))
        }
        return ModelTurn(
            id: id,
            modelName: modelName,
            messageProvider: messageProvider,
            toolsPolicy: toolsPolicy,
            modeValue: modeValue,
            outputWrites: outputWrites + [write],
            messageWrites: messageWrites,
            isStart: isStart
        )
    }

    public func writesMessages(to key: HiveChannelKey<Schema, [HiveChatMessage]>) -> ModelTurn<Schema> {
        let write: @Sendable ([HiveChatMessage]) throws -> AnyHiveWrite<Schema> = { messages in
            AnyHiveWrite(key, messages)
        }
        return ModelTurn(
            id: id,
            modelName: modelName,
            messageProvider: messageProvider,
            toolsPolicy: toolsPolicy,
            modeValue: modeValue,
            outputWrites: outputWrites,
            messageWrites: messageWrites + [write],
            isStart: isStart
        )
    }

    public func apply(to builder: inout HiveGraphBuilder<Schema>, design _: inout WorkflowDesign) throws {
        let modelName = modelName
        let messageProvider = messageProvider
        let toolsPolicy = toolsPolicy
        let modeValue = modeValue
        let outputWrites = outputWrites
        let messageWrites = messageWrites

        builder.addNode(id) { input in
            let tools: [HiveToolDefinition] = switch toolsPolicy {
            case .none:
                []
            case .environment:
                input.environment.tools?.listTools() ?? []
            case .explicit(let explicit):
                explicit
            }

            let messages = try messageProvider(input.store)
            let request = HiveChatRequest(model: modelName, messages: messages, tools: tools)

            let modelClient: AnyHiveModelClient
            if let router = input.environment.modelRouter {
                modelClient = router.route(request, hints: input.environment.inferenceHints)
            } else if let direct = input.environment.model {
                modelClient = direct
            } else {
                throw HiveRuntimeError.modelClientMissing
            }

            var writes: [AnyHiveWrite<Schema>] = []
            writes.reserveCapacity(outputWrites.count + messageWrites.count)

            switch modeValue {
            case .complete:
                input.emitStream(.modelInvocationStarted(model: modelName), [:])
                defer {
                    input.emitStream(.modelInvocationFinished, [:])
                }
                let response = try await modelClient.complete(request)

                for makeWrite in outputWrites {
                    writes.append(try makeWrite(response))
                }
                let messages = [response.message]
                for makeWrite in messageWrites {
                    writes.append(try makeWrite(messages))
                }
            case .agentLoop(let configuration):
                let result = try await HiveModelToolLoop.run(
                    request: request,
                    modelClient: modelClient,
                    toolRegistry: input.environment.tools,
                    configuration: configuration,
                    emitStream: { kind, metadata in
                        input.emitStream(kind, metadata)
                    }
                )

                for makeWrite in outputWrites {
                    writes.append(try makeWrite(result.finalResponse))
                }
                for makeWrite in messageWrites {
                    writes.append(try makeWrite(result.appendedMessages))
                }
            }

            return HiveNodeOutput(writes: writes)
        }
    }
}

extension ModelTurn: _WorkflowStartNodesProviding {
    func _declaredStartNodes() -> [HiveNodeID] {
        isStart ? [id] : []
    }
}
