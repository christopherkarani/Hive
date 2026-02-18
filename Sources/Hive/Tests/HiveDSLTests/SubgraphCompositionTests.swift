import Foundation
import Testing
@testable import HiveCore
@testable import HiveDSL

// MARK: - Test Infrastructure

private struct NoopClock: HiveClock {
    func nowNanoseconds() -> UInt64 { 0 }
    func sleep(nanoseconds: UInt64) async throws { try await Task.sleep(nanoseconds: nanoseconds) }
}

private struct NoopLogger: HiveLogger {
    func debug(_ message: String, metadata: [String: String]) {}
    func info(_ message: String, metadata: [String: String]) {}
    func error(_ message: String, metadata: [String: String]) {}
}

private func makeEnvironment<Schema: HiveSchema>(
    context: Schema.Context,
    checkpointStore: AnyHiveCheckpointStore<Schema>? = nil
) -> HiveEnvironment<Schema> {
    HiveEnvironment(
        context: context,
        clock: NoopClock(),
        logger: NoopLogger(),
        checkpointStore: checkpointStore
    )
}

private func drainEvents(_ stream: AsyncThrowingStream<HiveEvent, Error>) async -> [HiveEvent] {
    var events: [HiveEvent] = []
    do { for try await event in stream { events.append(event) } } catch {}
    return events
}

private actor InMemoryCheckpointStore<Schema: HiveSchema>: HiveCheckpointStore {
    private var checkpoints: [HiveCheckpoint<Schema>] = []

    func save(_ checkpoint: HiveCheckpoint<Schema>) async throws {
        checkpoints.append(checkpoint)
    }

    func loadLatest(threadID: HiveThreadID) async throws -> HiveCheckpoint<Schema>? {
        checkpoints
            .filter { $0.threadID == threadID }
            .max { lhs, rhs in
                if lhs.stepIndex == rhs.stepIndex { return lhs.id.rawValue < rhs.id.rawValue }
                return lhs.stepIndex < rhs.stepIndex
            }
    }
}

// MARK: - Schemas

/// Child schema: takes a string input, processes it, writes result to "childResult" channel.
private enum ChildSchema: HiveSchema {
    typealias Input = String

    static var channelSpecs: [AnyHiveChannelSpec<ChildSchema>] {
        let resultKey = HiveChannelKey<ChildSchema, String>(HiveChannelID("childResult"))
        let resultSpec = HiveChannelSpec(
            key: resultKey,
            scope: .global,
            reducer: .lastWriteWins(),
            updatePolicy: .single,
            initial: { "" },
            persistence: .untracked
        )
        return [AnyHiveChannelSpec(resultSpec)]
    }

    static func inputWrites(_ input: String, inputContext: HiveInputContext) throws -> [AnyHiveWrite<ChildSchema>] {
        let key = HiveChannelKey<ChildSchema, String>(HiveChannelID("childResult"))
        return [AnyHiveWrite(key, input)]
    }
}

/// Parent schema: has a "message" channel for input and a "result" channel for output.
private enum ParentSchema: HiveSchema {
    static var channelSpecs: [AnyHiveChannelSpec<ParentSchema>] {
        let messageKey = HiveChannelKey<ParentSchema, String>(HiveChannelID("message"))
        let messageSpec = HiveChannelSpec(
            key: messageKey,
            scope: .global,
            reducer: .lastWriteWins(),
            updatePolicy: .single,
            initial: { "" },
            persistence: .untracked
        )
        let resultKey = HiveChannelKey<ParentSchema, String>(HiveChannelID("result"))
        let resultSpec = HiveChannelSpec(
            key: resultKey,
            scope: .global,
            reducer: .lastWriteWins(),
            updatePolicy: .single,
            initial: { "" },
            persistence: .untracked
        )
        return [AnyHiveChannelSpec(messageSpec), AnyHiveChannelSpec(resultSpec)]
    }
}

// MARK: - Channel Keys

private let parentMessageKey = HiveChannelKey<ParentSchema, String>(HiveChannelID("message"))
private let parentResultKey = HiveChannelKey<ParentSchema, String>(HiveChannelID("result"))
private let childResultKey = HiveChannelKey<ChildSchema, String>(HiveChannelID("childResult"))

// MARK: - Tests

@Suite("SubgraphComposition")
struct SubgraphCompositionTests {

    @Test("Simple passthrough: parent A -> Subgraph(child) -> parent B")
    func simplePassthrough() async throws {
        // Build child graph: single node that uppercases the input value
        let childGraph = try Workflow<ChildSchema> {
            Node("transform") { input in
                let value: String = try input.store.get(childResultKey)
                return Effects {
                    Set(childResultKey, value.uppercased())
                    End()
                }
            }.start()
        }.compile()

        // Build parent workflow: A -> Subgraph -> B
        let workflow = Workflow<ParentSchema> {
            Node("A") { _ in
                Effects {
                    Set(parentMessageKey, "hello")
                    UseGraphEdges()
                }
            }.start()

            Subgraph<ParentSchema, ChildSchema>(
                "sub",
                childGraph: childGraph,
                inputMapping: { parentStore in
                    try parentStore.get(parentMessageKey)
                },
                environmentMapping: { parentEnv in
                    makeEnvironment(context: ())
                },
                outputMapping: { outcome, childStore in
                    let childResult = try childStore.get(childResultKey)
                    return [AnyHiveWrite(parentResultKey, childResult)]
                }
            )

            Node("B") { input in
                // B just ends; result was already written by subgraph output mapping
                Effects { End() }
            }

            Edge("A", to: "sub")
            Edge("sub", to: "B")
        }

        let graph = try workflow.compile()
        let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))
        let handle = await runtime.run(
            threadID: HiveThreadID("passthrough"),
            input: (),
            options: HiveRunOptions()
        )

        let eventsTask = Task { await drainEvents(handle.events) }
        _ = try await handle.outcome.value
        _ = await eventsTask.value

        guard let store = await runtime.getLatestStore(threadID: HiveThreadID("passthrough")) else {
            Issue.record("Store should exist after run")
            return
        }
        #expect(try store.get(parentResultKey) == "HELLO")
    }

    @Test("Multi-step child: child has A -> B -> C internally")
    func multiStepChild() async throws {
        // Multi-step child schema: transforms string through 3 steps
        enum MultiChildSchema: HiveSchema {
            typealias Input = String

            static var channelSpecs: [AnyHiveChannelSpec<MultiChildSchema>] {
                let key = HiveChannelKey<MultiChildSchema, String>(HiveChannelID("value"))
                let spec = HiveChannelSpec(
                    key: key,
                    scope: .global,
                    reducer: .lastWriteWins(),
                    updatePolicy: .single,
                    initial: { "" },
                    persistence: .untracked
                )
                return [AnyHiveChannelSpec(spec)]
            }

            static func inputWrites(_ input: String, inputContext: HiveInputContext) throws -> [AnyHiveWrite<MultiChildSchema>] {
                let key = HiveChannelKey<MultiChildSchema, String>(HiveChannelID("value"))
                return [AnyHiveWrite(key, input)]
            }
        }

        let childValueKey = HiveChannelKey<MultiChildSchema, String>(HiveChannelID("value"))

        // Child: A -> B -> C, each appending a suffix
        let childGraph = try Workflow<MultiChildSchema> {
            Node("cA") { input in
                let v: String = try input.store.get(childValueKey)
                return Effects {
                    Set(childValueKey, v + "-step1")
                    UseGraphEdges()
                }
            }.start()

            Node("cB") { input in
                let v: String = try input.store.get(childValueKey)
                return Effects {
                    Set(childValueKey, v + "-step2")
                    UseGraphEdges()
                }
            }

            Node("cC") { input in
                let v: String = try input.store.get(childValueKey)
                return Effects {
                    Set(childValueKey, v + "-step3")
                    End()
                }
            }

            Chain {
                Chain.Link.start("cA")
                Chain.Link.then("cB")
                Chain.Link.then("cC")
            }
        }.compile()

        // Parent: single start node is the subgraph
        let workflow = Workflow<ParentSchema> {
            Subgraph<ParentSchema, MultiChildSchema>(
                "sub",
                childGraph: childGraph,
                inputMapping: { _ in "init" },
                environmentMapping: { _ in makeEnvironment(context: ()) },
                outputMapping: { outcome, childStore in
                    let result = try childStore.get(childValueKey)
                    return [AnyHiveWrite(parentResultKey, result)]
                }
            ).start()
        }

        let graph = try workflow.compile()
        let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))
        let handle = await runtime.run(
            threadID: HiveThreadID("multistep"),
            input: (),
            options: HiveRunOptions()
        )

        let eventsTask = Task { await drainEvents(handle.events) }
        _ = try await handle.outcome.value
        _ = await eventsTask.value

        guard let store = await runtime.getLatestStore(threadID: HiveThreadID("multistep")) else {
            Issue.record("Store should exist after run")
            return
        }
        #expect(try store.get(parentResultKey) == "init-step1-step2-step3")
    }

    @Test("Child interrupt propagates as HiveSubgraphError.childInterrupted")
    func childInterruptPropagates() async throws {
        // Child schema with checkpointed channels (required for interrupt)
        enum InterruptChildSchema: HiveSchema {
            typealias Input = Void
            typealias InterruptPayload = String
            typealias ResumePayload = String

            static var channelSpecs: [AnyHiveChannelSpec<InterruptChildSchema>] {
                let key = HiveChannelKey<InterruptChildSchema, String>(HiveChannelID("data"))
                let spec = HiveChannelSpec(
                    key: key,
                    scope: .global,
                    reducer: .lastWriteWins(),
                    updatePolicy: .single,
                    initial: { "" },
                    codec: HiveAnyCodec(HiveJSONCodec<String>()),
                    persistence: .checkpointed
                )
                return [AnyHiveChannelSpec(spec)]
            }
        }

        // Child graph: single node that interrupts
        let childGraph = try Workflow<InterruptChildSchema> {
            Node("interrupter") { _ in
                Effects { Interrupt("need_approval") }
            }.start()
        }.compile()

        let childCheckpointStore = InMemoryCheckpointStore<InterruptChildSchema>()

        // Parent workflow with the subgraph
        let workflow = Workflow<ParentSchema> {
            Subgraph<ParentSchema, InterruptChildSchema>(
                "sub",
                childGraph: childGraph,
                inputMapping: { _ in () },
                environmentMapping: { _ in
                    makeEnvironment(
                        context: (),
                        checkpointStore: AnyHiveCheckpointStore(childCheckpointStore)
                    )
                },
                outputMapping: { _, _ in [] }
            ).start()
        }

        let graph = try workflow.compile()
        let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))
        let handle = await runtime.run(
            threadID: HiveThreadID("interrupt"),
            input: (),
            options: HiveRunOptions()
        )

        let eventsTask = Task { await drainEvents(handle.events) }

        // The parent node should throw because the child interrupted
        do {
            _ = try await handle.outcome.value
            Issue.record("Expected error from child interrupt")
        } catch let error as HiveSubgraphError {
            guard case .childInterrupted(let interruptID) = error else {
                Issue.record("Expected childInterrupted, got: \(error)")
                return
            }
            // The interrupt ID is runtime-generated, just verify it exists
            #expect(!interruptID.rawValue.isEmpty)
        }

        _ = await eventsTask.value
    }

    @Test("Full parent chain: A -> Subgraph -> B end-to-end")
    func parentChainWithSubgraph() async throws {
        let childGraph = try Workflow<ChildSchema> {
            Node("process") { input in
                let value: String = try input.store.get(childResultKey)
                return Effects {
                    Set(childResultKey, "processed:\(value)")
                    End()
                }
            }.start()
        }.compile()

        let workflow = Workflow<ParentSchema> {
            Node("prepare") { _ in
                Effects {
                    Set(parentMessageKey, "data")
                    UseGraphEdges()
                }
            }.start()

            Subgraph<ParentSchema, ChildSchema>(
                "sub",
                childGraph: childGraph,
                inputMapping: { parentStore in
                    try parentStore.get(parentMessageKey)
                },
                environmentMapping: { _ in makeEnvironment(context: ()) },
                outputMapping: { _, childStore in
                    let result = try childStore.get(childResultKey)
                    return [AnyHiveWrite(parentResultKey, result)]
                }
            )

            Node("finalize") { input in
                let result: String = try input.store.get(parentResultKey)
                return Effects {
                    Set(parentResultKey, result + ":done")
                    End()
                }
            }

            Chain {
                Chain.Link.start("prepare")
                Chain.Link.then("sub")
                Chain.Link.then("finalize")
            }
        }

        let graph = try workflow.compile()
        let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))
        let handle = await runtime.run(
            threadID: HiveThreadID("chain"),
            input: (),
            options: HiveRunOptions()
        )

        let eventsTask = Task { await drainEvents(handle.events) }
        _ = try await handle.outcome.value
        _ = await eventsTask.value

        guard let store = await runtime.getLatestStore(threadID: HiveThreadID("chain")) else {
            Issue.record("Store should exist after run")
            return
        }
        #expect(try store.get(parentResultKey) == "processed:data:done")
    }

    @Test("Subgraph with .start() marks node as start")
    func subgraphStartMarker() throws {
        let childGraph = try Workflow<ChildSchema> {
            Node("noop") { _ in Effects { End() } }.start()
        }.compile()

        let workflow = Workflow<ParentSchema> {
            Subgraph<ParentSchema, ChildSchema>(
                "sub",
                childGraph: childGraph,
                inputMapping: { _ in "" },
                environmentMapping: { _ in makeEnvironment(context: ()) },
                outputMapping: { _, _ in [] }
            ).start()
        }

        let graph = try workflow.compile()
        #expect(graph.start == [HiveNodeID("sub")])
        #expect(graph.nodesByID[HiveNodeID("sub")] != nil)
    }

    @Test("Subgraph without .start() is not a start node")
    func subgraphNotStartByDefault() throws {
        let childGraph = try Workflow<ChildSchema> {
            Node("noop") { _ in Effects { End() } }.start()
        }.compile()

        let workflow = Workflow<ParentSchema> {
            Node("entry") { _ in Effects { UseGraphEdges() } }.start()

            Subgraph<ParentSchema, ChildSchema>(
                "sub",
                childGraph: childGraph,
                inputMapping: { _ in "" },
                environmentMapping: { _ in makeEnvironment(context: ()) },
                outputMapping: { _, _ in [] }
            )

            Edge("entry", to: "sub")
        }

        let graph = try workflow.compile()
        #expect(graph.start == [HiveNodeID("entry")])
        #expect(graph.nodesByID[HiveNodeID("sub")] != nil)
    }
}
