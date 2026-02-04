import Foundation
import Testing
@testable import HiveCore

private let jsonEncoder = JSONEncoder()
private let jsonDecoder = JSONDecoder()

private func roundTrip<T: Codable>(_ value: T, as type: T.Type = T.self) throws -> T {
    let data = try jsonEncoder.encode(value)
    return try jsonDecoder.decode(T.self, from: data)
}

private func expectToolCallMatches(_ lhs: HiveToolCall, _ rhs: HiveToolCall) {
    #expect(lhs.id == rhs.id)
    #expect(lhs.name == rhs.name)
    #expect(lhs.argumentsJSON == rhs.argumentsJSON)
}

@Test("HiveChatRole Codable round-trip preserves raw values")
func hiveChatRoleCodableRoundTrip() throws {
    for role in [HiveChatRole.system, .user, .assistant, .tool] {
        let decoded = try roundTrip(role)
        #expect(decoded == role)
        #expect(decoded.rawValue == role.rawValue)
    }
}

@Test("HiveToolDefinition Codable round-trip preserves fields")
func hiveToolDefinitionCodableRoundTrip() throws {
    let tool = HiveToolDefinition(
        name: "search",
        description: "Search the web",
        parametersJSONSchema: "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}}}"
    )
    let decoded = try roundTrip(tool)
    #expect(decoded.name == tool.name)
    #expect(decoded.description == tool.description)
    #expect(decoded.parametersJSONSchema == tool.parametersJSONSchema)
}

@Test("HiveToolCall Codable round-trip preserves fields")
func hiveToolCallCodableRoundTrip() throws {
    let call = HiveToolCall(
        id: "call-1",
        name: "search",
        argumentsJSON: "{\"query\":\"hive\"}"
    )
    let decoded = try roundTrip(call)
    expectToolCallMatches(decoded, call)
}

@Test("HiveToolResult Codable round-trip preserves fields")
func hiveToolResultCodableRoundTrip() throws {
    let result = HiveToolResult(toolCallID: "call-1", content: "done")
    let decoded = try roundTrip(result)
    #expect(decoded.toolCallID == result.toolCallID)
    #expect(decoded.content == result.content)
}

@Test("HiveChatMessageOp Codable round-trip preserves raw values")
func hiveChatMessageOpCodableRoundTrip() throws {
    for op in [HiveChatMessageOp.remove, .removeAll] {
        let decoded = try roundTrip(op)
        #expect(decoded == op)
        #expect(decoded.rawValue == op.rawValue)
    }
}

@Test("HiveChatMessage Codable round-trip preserves all fields")
func hiveChatMessageCodableRoundTrip() throws {
    let toolCall = HiveToolCall(id: "call-42", name: "math", argumentsJSON: "{\"x\":2}")
    let message = HiveChatMessage(
        id: "msg-1",
        role: .assistant,
        content: "result",
        name: "assistant",
        toolCallID: "call-42",
        toolCalls: [toolCall],
        op: .remove
    )

    let decoded = try roundTrip(message)
    #expect(decoded.id == message.id)
    #expect(decoded.role == message.role)
    #expect(decoded.content == message.content)
    #expect(decoded.name == message.name)
    #expect(decoded.toolCallID == message.toolCallID)
    #expect(decoded.op == message.op)
    #expect(decoded.toolCalls.count == 1)
    if let decodedCall = decoded.toolCalls.first {
        expectToolCallMatches(decodedCall, toolCall)
    }
}

@Test("HiveChatMessage Codable round-trip preserves nil/empty defaults")
func hiveChatMessageCodableRoundTripDefaults() throws {
    let message = HiveChatMessage(id: "msg-2", role: .user, content: "hello")
    let decoded = try roundTrip(message)
    #expect(decoded.id == message.id)
    #expect(decoded.role == message.role)
    #expect(decoded.content == message.content)
    #expect(decoded.name == nil)
    #expect(decoded.toolCallID == nil)
    #expect(decoded.op == nil)
    #expect(decoded.toolCalls.isEmpty)
}

@Test("HiveChatRequest/Response Codable round-trip preserves fields")
func hiveChatRequestResponseCodableRoundTrip() throws {
    let tool = HiveToolDefinition(name: "echo", description: "Echo input", parametersJSONSchema: "{\"type\":\"object\"}")
    let message = HiveChatMessage(id: "msg-2", role: .user, content: "hello")
    let request = HiveChatRequest(model: "test-model", messages: [message], tools: [tool])

    let decodedRequest = try roundTrip(request)
    #expect(decodedRequest.model == request.model)
    #expect(decodedRequest.messages.count == 1)
    #expect(decodedRequest.tools.count == 1)
    #expect(decodedRequest.messages.first?.id == message.id)
    #expect(decodedRequest.tools.first?.name == tool.name)

    let response = HiveChatResponse(message: message)
    let decodedResponse = try roundTrip(response)
    #expect(decodedResponse.message.id == response.message.id)
    #expect(decodedResponse.message.role == response.message.role)
    #expect(decodedResponse.message.content == response.message.content)
}

@Test("HiveLatencyTier and HiveNetworkState raw values are stable")
func hiveInferenceEnumsRawValues() throws {
    #expect(HiveLatencyTier.interactive.rawValue == "interactive")
    #expect(HiveLatencyTier.background.rawValue == "background")
    #expect(HiveNetworkState.offline.rawValue == "offline")
    #expect(HiveNetworkState.online.rawValue == "online")
    #expect(HiveNetworkState.metered.rawValue == "metered")
}
