import CryptoKit
import Foundation

/// Deterministic runtime for executing a compiled graph.
public actor HiveRuntime<Schema: HiveSchema>: Sendable {
    public init(graph: CompiledHiveGraph<Schema>, environment: HiveEnvironment<Schema>) {
        self.graph = graph
        self.environment = environment
        do {
            let registry = try HiveSchemaRegistry<Schema>()
            self.registry = registry
            self.initialCache = HiveInitialCache(registry: registry)
            self.storeSupport = HiveStoreSupport(registry: registry)
        } catch {
            preconditionFailure("Failed to initialize HiveRuntime: \(error)")
        }
        self.threadStates = [:]
        self.threadQueues = [:]
    }

    public func run(
        threadID: HiveThreadID,
        input: Schema.Input,
        options: HiveRunOptions
    ) -> HiveRunHandle<Schema> {
        let attemptID = HiveRunAttemptID(UUID())
        let runID = ensureThreadState(for: threadID).runID
        let capacity = max(1, options.eventBufferCapacity)
        let streamController = HiveEventStreamController(capacity: capacity)
        let events = streamController.makeStream()

        let previous = threadQueues[threadID]
        let outcome = Task { [weak self] in
            if let previous {
                await previous.value
            }
            guard let self else {
                throw CancellationError()
            }
            return try await self.runAttempt(
                threadID: threadID,
                input: input,
                options: options,
                runID: runID,
                attemptID: attemptID,
                streamController: streamController
            )
        }

        threadQueues[threadID] = Task {
            _ = try? await outcome.value
        }

        return HiveRunHandle(
            runID: runID,
            attemptID: attemptID,
            events: events,
            outcome: outcome
        )
    }

    public func resume(
        threadID: HiveThreadID,
        interruptID: HiveInterruptID,
        payload: Schema.ResumePayload,
        options: HiveRunOptions
    ) -> HiveRunHandle<Schema> {
        makeFailFastHandle(
            threadID: threadID,
            options: options,
            error: HiveRuntimeError.invalidRunOptions("resume is not implemented in Plan 05")
        )
    }

    public func applyExternalWrites(
        threadID: HiveThreadID,
        writes: [AnyHiveWrite<Schema>],
        options: HiveRunOptions
    ) -> HiveRunHandle<Schema> {
        makeFailFastHandle(
            threadID: threadID,
            options: options,
            error: HiveRuntimeError.invalidRunOptions("applyExternalWrites is not implemented in Plan 05")
        )
    }

    public func getLatestStore(threadID: HiveThreadID) -> HiveGlobalStore<Schema>? {
        threadStates[threadID]?.global
    }

    public func getLatestCheckpoint(threadID: HiveThreadID) async throws -> HiveCheckpoint<Schema>? {
        nil
    }

    // MARK: - Private

    private let graph: CompiledHiveGraph<Schema>
    private let environment: HiveEnvironment<Schema>
    private let registry: HiveSchemaRegistry<Schema>
    private let initialCache: HiveInitialCache<Schema>
    private let storeSupport: HiveStoreSupport<Schema>

    private var threadStates: [HiveThreadID: ThreadState<Schema>]
    private var threadQueues: [HiveThreadID: Task<Void, Never>]

    private func makeFailFastHandle(
        threadID: HiveThreadID,
        options: HiveRunOptions,
        error: Error
    ) -> HiveRunHandle<Schema> {
        let attemptID = HiveRunAttemptID(UUID())
        let runID = ensureThreadState(for: threadID).runID
        let capacity = max(1, options.eventBufferCapacity)
        let streamController = HiveEventStreamController(capacity: capacity)
        let events = streamController.makeStream()
        streamController.finish(throwing: error)

        let outcome = Task<HiveRunOutcome<Schema>, Error> {
            throw error
        }

        return HiveRunHandle(
            runID: runID,
            attemptID: attemptID,
            events: events,
            outcome: outcome
        )
    }

    private func ensureThreadState(for threadID: HiveThreadID) -> ThreadState<Schema> {
        if let existing = threadStates[threadID] {
            return existing
        }

        let runID = HiveRunID(UUID())
        let global = HiveGlobalStore(registry: registry, initialCache: initialCache)
        let joinSeen = Dictionary(uniqueKeysWithValues: graph.joinEdges.map { ($0.id, Set<HiveNodeID>()) })
        let state = ThreadState(
            runID: runID,
            stepIndex: 0,
            global: global,
            frontier: [],
            joinSeenParents: joinSeen,
            interruption: nil,
            latestCheckpointID: nil
        )
        threadStates[threadID] = state
        return state
    }

    private func runAttempt(
        threadID: HiveThreadID,
        input: Schema.Input,
        options: HiveRunOptions,
        runID: HiveRunID,
        attemptID: HiveRunAttemptID,
        streamController: HiveEventStreamController
    ) async throws -> HiveRunOutcome<Schema> {
        let emitter = HiveEventEmitter(
            runID: runID,
            attemptID: attemptID,
            streamController: streamController
        )

        emitter.emit(kind: .runStarted(threadID: threadID), stepIndex: nil, taskOrdinal: nil)

        var state = ensureThreadState(for: threadID)

        do {
            try validateRunOptions(options)
            switch options.checkpointPolicy {
            case .disabled:
                break
            case .everyStep, .every, .onInterrupt:
                if environment.checkpointStore == nil {
                    throw HiveRuntimeError.checkpointStoreMissing
                }
            }
            try validateRetryPolicies()
            try validateRequiredCodecs()

            if let interruption = state.interruption {
                throw HiveRuntimeError.interruptPending(interruptID: interruption.id)
            }

            if state.frontier.isEmpty {
                state.frontier = graph.start.map { HiveFrontierTask(seed: HiveTaskSeed(nodeID: $0), provenance: .graph) }
            }

            let inputContext = HiveInputContext(threadID: threadID, runID: state.runID, stepIndex: state.stepIndex)
            let inputWrites = try Schema.inputWrites(input, inputContext: inputContext)
            if !inputWrites.isEmpty {
                var global = state.global
                try applyInputWrites(inputWrites, to: &global)
                state.global = global
            }
            threadStates[threadID] = state

            while true {
                if Task.isCancelled {
                    let output = try buildOutput(options: options, state: state)
                    emitter.emit(kind: .runCancelled, stepIndex: nil, taskOrdinal: nil)
                    streamController.finish()
                    return .cancelled(output: output, checkpointID: state.latestCheckpointID)
                }

                if state.frontier.isEmpty {
                    let output = try buildOutput(options: options, state: state)
                    emitter.emit(kind: .runFinished, stepIndex: nil, taskOrdinal: nil)
                    streamController.finish()
                    return .finished(output: output, checkpointID: state.latestCheckpointID)
                }

                let (nextState, writtenChannels, dropped) = try await executeStep(
                    state: state,
                    threadID: threadID,
                    attemptID: attemptID,
                    options: options,
                    emitter: emitter
                )

                state = nextState
                threadStates[threadID] = state

                if !writtenChannels.isEmpty {
                    for channelID in writtenChannels {
                        let payloadHash = try payloadHash(for: channelID, in: state.global)
                        emitter.emit(
                            kind: .writeApplied(channelID: channelID, payloadHash: payloadHash),
                            stepIndex: state.stepIndex - 1,
                            taskOrdinal: nil,
                            metadata: try writeAppliedMetadata(
                                for: channelID,
                                in: state.global,
                                debugPayloads: options.debugPayloads
                            )
                        )
                    }
                }

                if dropped.droppedModelTokenEvents > 0 || dropped.droppedDebugEvents > 0 {
                    emitter.emit(
                        kind: .streamBackpressure(
                            droppedModelTokenEvents: dropped.droppedModelTokenEvents,
                            droppedDebugEvents: dropped.droppedDebugEvents
                        ),
                        stepIndex: state.stepIndex - 1,
                        taskOrdinal: nil
                    )
                }

                emitter.emit(
                    kind: .stepFinished(stepIndex: state.stepIndex - 1, nextFrontierCount: state.frontier.count),
                    stepIndex: state.stepIndex - 1,
                    taskOrdinal: nil
                )

                if state.frontier.isEmpty {
                    let output = try buildOutput(options: options, state: state)
                    emitter.emit(kind: .runFinished, stepIndex: nil, taskOrdinal: nil)
                    streamController.finish()
                    return .finished(output: output, checkpointID: state.latestCheckpointID)
                }
            }
        } catch is CancellationError {
            let output = try buildOutput(options: options, state: state)
            emitter.emit(kind: .runCancelled, stepIndex: nil, taskOrdinal: nil)
            streamController.finish()
            return .cancelled(output: output, checkpointID: state.latestCheckpointID)
        } catch {
            streamController.finish(throwing: error)
            throw error
        }
    }

    private func validateRunOptions(_ options: HiveRunOptions) throws {
        guard options.maxSteps >= 0 else {
            throw HiveRuntimeError.invalidRunOptions("maxSteps must be >= 0")
        }
        guard options.maxConcurrentTasks >= 1 else {
            throw HiveRuntimeError.invalidRunOptions("maxConcurrentTasks must be >= 1")
        }
        guard options.eventBufferCapacity >= 1 else {
            throw HiveRuntimeError.invalidRunOptions("eventBufferCapacity must be >= 1")
        }
        if case let .every(steps) = options.checkpointPolicy, steps < 1 {
            throw HiveRuntimeError.invalidRunOptions("checkpointPolicy.every requires steps >= 1")
        }
        if let override = options.outputProjectionOverride {
            _ = try normalizedOutputProjection(override)
        }
    }

    private func validateRetryPolicies() throws {
        var invalid: HiveNodeID?
        for (id, node) in graph.nodesByID {
            if case let .exponentialBackoff(_, factor, maxAttempts, _) = node.retryPolicy {
                let invalidPolicy = maxAttempts < 1 || !factor.isFinite || factor < 1.0
                if invalidPolicy {
                    if let current = invalid {
                        if HiveOrdering.lexicographicallyPrecedes(id.rawValue, current.rawValue) {
                            invalid = id
                        }
                    } else {
                        invalid = id
                    }
                }
            }
        }
        if let invalid {
            throw HiveRuntimeError.invalidRunOptions("invalid retry policy for node \(invalid.rawValue)")
        }
    }

    private func validateRequiredCodecs() throws {
        if let missing = registry.firstMissingRequiredCodecID() {
            throw HiveRuntimeError.missingCodec(channelID: missing)
        }
    }

    private func normalizedOutputProjection(_ projection: HiveOutputProjection) throws -> HiveOutputProjection {
        let normalized = projection.normalized()
        switch normalized {
        case .fullStore:
            return normalized
        case .channels(let ids):
            for id in ids {
                guard let spec = registry.channelSpecsByID[id] else {
                    throw HiveRuntimeError.invalidRunOptions("output projection includes unknown channel \(id.rawValue)")
                }
                if spec.scope == .taskLocal {
                    throw HiveRuntimeError.invalidRunOptions("output projection includes task-local channel \(id.rawValue)")
                }
            }
            return normalized
        }
    }

    private func buildOutput(options: HiveRunOptions, state: ThreadState<Schema>) throws -> HiveRunOutput<Schema> {
        let projection = try normalizedOutputProjection(
            options.outputProjectionOverride ?? graph.outputProjection
        )

        switch projection {
        case .fullStore:
            return .fullStore(state.global)
        case .channels(let ids):
            var values: [HiveProjectedChannelValue] = []
            values.reserveCapacity(ids.count)
            for id in ids {
                let value = try state.global.valueAny(for: id)
                values.append(HiveProjectedChannelValue(id: id, value: value))
            }
            return .channels(values)
        }
    }

    private func applyInputWrites(
        _ writes: [AnyHiveWrite<Schema>],
        to global: inout HiveGlobalStore<Schema>
    ) throws {
        var globalWritesByChannel: [HiveChannelID: [AnyHiveWrite<Schema>]] = [:]
        for write in writes {
            guard let spec = registry.channelSpecsByID[write.channelID] else {
                throw HiveRuntimeError.unknownChannelID(write.channelID)
            }
            if spec.scope != .global {
                throw HiveRuntimeError.taskLocalWriteNotAllowed
            }
            try storeSupport.validateValueType(write.value, spec: spec)
            globalWritesByChannel[write.channelID, default: []].append(write)
        }

        for spec in registry.sortedChannelSpecs where spec.scope == .global {
            let writesForChannel = globalWritesByChannel[spec.id] ?? []
            if writesForChannel.isEmpty { continue }
            if spec.updatePolicy == .single, writesForChannel.count > 1 {
                throw HiveRuntimeError.updatePolicyViolation(
                    channelID: spec.id,
                    policy: .single,
                    writeCount: writesForChannel.count
                )
            }
            var current = try global.valueAny(for: spec.id)
            for write in writesForChannel {
                current = try spec._reduceBox(current, write.value)
            }
            try global.setAny(current, for: spec.id)
        }
    }

    private func executeStep(
        state: ThreadState<Schema>,
        threadID: HiveThreadID,
        attemptID: HiveRunAttemptID,
        options: HiveRunOptions,
        emitter: HiveEventEmitter
    ) async throws -> (ThreadState<Schema>, [HiveChannelID], HiveDroppedEventCounts) {
        let stepIndex = state.stepIndex
        guard UInt32(exactly: stepIndex) != nil else {
            throw HiveRuntimeError.stepIndexOutOfRange(stepIndex: stepIndex)
        }

        let frontier = state.frontier
        let tasks = try buildTasks(
            frontier: frontier,
            runID: state.runID,
            stepIndex: stepIndex,
            debugPayloads: options.debugPayloads
        )

        emitter.emit(
            kind: .stepStarted(stepIndex: stepIndex, frontierCount: tasks.count),
            stepIndex: stepIndex,
            taskOrdinal: nil
        )

        for task in tasks {
            emitter.emit(
                kind: .taskStarted(node: task.nodeID, taskID: task.id),
                stepIndex: stepIndex,
                taskOrdinal: task.ordinal
            )
        }

        if Task.isCancelled {
            for task in tasks {
                emitter.emit(
                    kind: .taskFailed(
                        node: task.nodeID,
                        taskID: task.id,
                        errorDescription: HiveErrorDescription.describe(CancellationError(), debugPayloads: options.debugPayloads)
                    ),
                    stepIndex: stepIndex,
                    taskOrdinal: task.ordinal
                )
            }
            throw CancellationError()
        }

        let droppedCounter = HiveDroppedEventCounter()

        let results = await Self.executeTasks(
            tasks: tasks,
            options: options,
            stepIndex: stepIndex,
            threadID: threadID,
            attemptID: attemptID,
            runID: state.runID,
            graph: graph,
            environment: environment,
            registry: registry,
            initialCache: initialCache,
            preStepGlobal: state.global,
            emitter: emitter,
            droppedCounter: droppedCounter
        )

        if Task.isCancelled || results.contains(where: { $0.error is CancellationError }) {
            if options.deterministicTokenStreaming == false {
                // Live stream events already emitted (if any). Ensure determinism for task failure surface.
            }

            for task in tasks {
                emitter.emit(
                    kind: .taskFailed(
                        node: task.nodeID,
                        taskID: task.id,
                        errorDescription: HiveErrorDescription.describe(CancellationError(), debugPayloads: options.debugPayloads)
                    ),
                    stepIndex: stepIndex,
                    taskOrdinal: task.ordinal
                )
            }
            throw CancellationError()
        }

        var dropped = droppedCounter.snapshot()
        if options.deterministicTokenStreaming {
            for result in results {
                dropped.droppedModelTokenEvents += result.streamDrops.droppedModelTokenEvents
                dropped.droppedDebugEvents += result.streamDrops.droppedDebugEvents
            }

            for result in results {
                guard let events = result.streamEvents else { continue }
                for event in events {
                    let enqueueResult = emitter.emit(
                        kind: event.kind,
                        stepIndex: stepIndex,
                        taskOrdinal: event.taskOrdinal,
                        metadata: event.metadata
                    )
                    dropped.record(enqueueResult)
                }
            }
        }

        var firstError: Error?
        for (index, result) in results.enumerated() {
            let task = tasks[index]
            if let error = result.error {
                if firstError == nil {
                    firstError = error
                }
                emitter.emit(
                    kind: .taskFailed(
                        node: task.nodeID,
                        taskID: task.id,
                        errorDescription: HiveErrorDescription.describe(error, debugPayloads: options.debugPayloads)
                    ),
                    stepIndex: stepIndex,
                    taskOrdinal: task.ordinal
                )
            } else {
                emitter.emit(
                    kind: .taskFinished(node: task.nodeID, taskID: task.id),
                    stepIndex: stepIndex,
                    taskOrdinal: task.ordinal
                )
            }
        }

        if let firstError {
            throw firstError
        }

        let outputs = results.map { result -> HiveNodeOutput<Schema> in
            guard let output = result.output else {
                preconditionFailure("Task result missing output without error.")
            }
            return output
        }
        let commitResult = try commitStep(
            state: state,
            tasks: tasks,
            outputs: outputs,
            options: options
        )

        var nextState = state
        nextState.stepIndex += 1
        nextState.global = commitResult.global
        nextState.frontier = commitResult.frontier
        nextState.joinSeenParents = commitResult.joinSeenParents

        return (nextState, commitResult.writtenGlobalChannels, dropped)
    }

    private func buildTasks(
        frontier: [HiveFrontierTask<Schema>],
        runID: HiveRunID,
        stepIndex: Int,
        debugPayloads: Bool
    ) throws -> [HiveTask<Schema>] {
        var tasks: [HiveTask<Schema>] = []
        tasks.reserveCapacity(frontier.count)

        for (ordinal, entry) in frontier.enumerated() {
            guard UInt32(exactly: ordinal) != nil else {
                throw HiveRuntimeError.taskOrdinalOutOfRange(ordinal: ordinal)
            }
            let fingerprint = try HiveTaskLocalFingerprint.digest(
                registry: registry,
                initialCache: initialCache,
                overlay: entry.seed.local,
                debugPayloads: debugPayloads
            )
            let taskID = try makeTaskID(
                runID: runID,
                stepIndex: stepIndex,
                nodeID: entry.seed.nodeID,
                ordinal: ordinal,
                localFingerprint: fingerprint
            )
            tasks.append(
                HiveTask(
                    id: taskID,
                    ordinal: ordinal,
                    provenance: entry.provenance,
                    nodeID: entry.seed.nodeID,
                    local: entry.seed.local
                )
            )
        }
        return tasks
    }

    private static func executeTasks(
        tasks: [HiveTask<Schema>],
        options: HiveRunOptions,
        stepIndex: Int,
        threadID: HiveThreadID,
        attemptID: HiveRunAttemptID,
        runID: HiveRunID,
        graph: CompiledHiveGraph<Schema>,
        environment: HiveEnvironment<Schema>,
        registry: HiveSchemaRegistry<Schema>,
        initialCache: HiveInitialCache<Schema>,
        preStepGlobal: HiveGlobalStore<Schema>,
        emitter: HiveEventEmitter,
        droppedCounter: HiveDroppedEventCounter
    ) async -> [TaskExecutionResult<Schema>] {
        if tasks.isEmpty { return [] }
        let concurrency = max(1, min(options.maxConcurrentTasks, tasks.count))
        var results = Array(repeating: TaskExecutionResult<Schema>.empty, count: tasks.count)

        await withTaskGroup(of: (Int, TaskExecutionResult<Schema>).self) { group in
            var nextIndex = 0
            func addTask(_ index: Int) {
                let task = tasks[index]
                group.addTask {
                    let result = await Self.executeTask(
                        task: task,
                        stepIndex: stepIndex,
                        threadID: threadID,
                        attemptID: attemptID,
                        runID: runID,
                        options: options,
                        graph: graph,
                        environment: environment,
                        registry: registry,
                        initialCache: initialCache,
                        preStepGlobal: preStepGlobal,
                        emitter: emitter,
                        droppedCounter: droppedCounter
                    )
                    return (index, result)
                }
            }

            while nextIndex < concurrency {
                addTask(nextIndex)
                nextIndex += 1
            }

            while let (index, result) = await group.next() {
                results[index] = result
                if nextIndex < tasks.count {
                    addTask(nextIndex)
                    nextIndex += 1
                }
            }
        }

        return results
    }

    private static func executeTask(
        task: HiveTask<Schema>,
        stepIndex: Int,
        threadID: HiveThreadID,
        attemptID: HiveRunAttemptID,
        runID: HiveRunID,
        options: HiveRunOptions,
        graph: CompiledHiveGraph<Schema>,
        environment: HiveEnvironment<Schema>,
        registry: HiveSchemaRegistry<Schema>,
        initialCache: HiveInitialCache<Schema>,
        preStepGlobal: HiveGlobalStore<Schema>,
        emitter: HiveEventEmitter,
        droppedCounter: HiveDroppedEventCounter
    ) async -> TaskExecutionResult<Schema> {
        guard let node = graph.nodesByID[task.nodeID] else {
            return TaskExecutionResult(error: HiveRuntimeError.unknownNodeID(task.nodeID))
        }

        switch node.retryPolicy {
        case .none:
            return await runNodeAttempt(
                node: node,
                task: task,
                stepIndex: stepIndex,
                threadID: threadID,
                attemptID: attemptID,
                runID: runID,
                options: options,
                environment: environment,
                registry: registry,
                initialCache: initialCache,
                preStepGlobal: preStepGlobal,
                emitter: emitter,
                droppedCounter: droppedCounter
            )
        case let .exponentialBackoff(initialNanoseconds, factor, maxAttempts, maxNanoseconds):
            var attempt = 1
            while attempt <= maxAttempts {
                let result = await runNodeAttempt(
                    node: node,
                    task: task,
                    stepIndex: stepIndex,
                    threadID: threadID,
                    attemptID: attemptID,
                    runID: runID,
                    options: options,
                    environment: environment,
                    registry: registry,
                    initialCache: initialCache,
                    preStepGlobal: preStepGlobal,
                    emitter: emitter,
                    droppedCounter: droppedCounter
                )
                if result.error == nil {
                    return result
                }
                if attempt == maxAttempts {
                    return result
                }
                let delay = min(maxNanoseconds, UInt64(Double(initialNanoseconds) * pow(factor, Double(attempt - 1))))
                do {
                    try await environment.clock.sleep(nanoseconds: delay)
                } catch {
                    return TaskExecutionResult(error: error)
                }
                attempt += 1
            }
            return TaskExecutionResult(error: HiveRuntimeError.invalidRunOptions("retry attempts exhausted"))
        }
    }

    private static func runNodeAttempt(
        node: HiveCompiledNode<Schema>,
        task: HiveTask<Schema>,
        stepIndex: Int,
        threadID: HiveThreadID,
        attemptID: HiveRunAttemptID,
        runID: HiveRunID,
        options: HiveRunOptions,
        environment: HiveEnvironment<Schema>,
        registry: HiveSchemaRegistry<Schema>,
        initialCache: HiveInitialCache<Schema>,
        preStepGlobal: HiveGlobalStore<Schema>,
        emitter: HiveEventEmitter,
        droppedCounter: HiveDroppedEventCounter
    ) async -> TaskExecutionResult<Schema> {
        let bufferingCapacity = max(1, options.eventBufferCapacity)
        let streamBuffer: HivePerAttemptStreamBuffer? = options.deterministicTokenStreaming
            ? HivePerAttemptStreamBuffer(capacity: bufferingCapacity, stepIndex: stepIndex, taskOrdinal: task.ordinal)
            : nil

        let storeView = HiveStoreView(
            global: preStepGlobal,
            taskLocal: task.local,
            initialCache: initialCache,
            registry: registry
        )

        let runContext = HiveRunContext<Schema>(
            runID: runID,
            threadID: threadID,
            attemptID: attemptID,
            stepIndex: stepIndex,
            taskID: task.id,
            resume: nil
        )

        let input = HiveNodeInput(
            store: storeView,
            run: runContext,
            context: environment.context,
            environment: environment,
            emitStream: { kind, metadata in
                if let streamBuffer {
                    streamBuffer.record(kind: mapStream(kind), metadata: metadata)
                    return
                }
                let enqueueResult = emitter.emit(
                    kind: mapStream(kind),
                    stepIndex: stepIndex,
                    taskOrdinal: task.ordinal,
                    metadata: metadata
                )
                droppedCounter.record(enqueueResult)
            },
            emitDebug: { name, metadata in
                if let streamBuffer {
                    streamBuffer.record(kind: .customDebug(name: name), metadata: metadata)
                    return
                }
                let enqueueResult = emitter.emit(
                    kind: .customDebug(name: name),
                    stepIndex: stepIndex,
                    taskOrdinal: task.ordinal,
                    metadata: metadata
                )
                droppedCounter.record(enqueueResult)
            }
        )

        do {
            let output = try await node.run(input)
            if let streamBuffer {
                let snapshot = streamBuffer.snapshot()
                if let overflowError = snapshot.overflowError {
                    return TaskExecutionResult(error: overflowError)
                }
                return TaskExecutionResult(output: output, streamEvents: snapshot.events, streamDrops: snapshot.dropped)
            }
            return TaskExecutionResult(output: output, error: nil, streamEvents: nil, streamDrops: .init())
        } catch {
            if options.deterministicTokenStreaming {
                // Failed-attempt stream events are discarded in this mode.
                return TaskExecutionResult(error: error)
            }
            return TaskExecutionResult(error: error)
        }
    }

    private func commitStep(
        state: ThreadState<Schema>,
        tasks: [HiveTask<Schema>],
        outputs: [HiveNodeOutput<Schema>],
        options: HiveRunOptions
    ) throws -> CommitResult<Schema> {
        let (perTaskWrites, globalWritesByChannel) = try collectWrites(tasks: tasks, outputs: outputs)

        var postGlobal = state.global

        for spec in registry.sortedChannelSpecs where spec.scope == .global {
            let writes = globalWritesByChannel[spec.id] ?? []
            if writes.isEmpty { continue }
            if spec.updatePolicy == .single, writes.count > 1 {
                throw HiveRuntimeError.updatePolicyViolation(
                    channelID: spec.id,
                    policy: .single,
                    writeCount: writes.count
                )
            }
        }

        var writtenGlobalChannels: [HiveChannelID] = []
        for spec in registry.sortedChannelSpecs where spec.scope == .global {
            guard let writes = globalWritesByChannel[spec.id], !writes.isEmpty else { continue }
            let ordered = writes.sorted { lhs, rhs in
                if lhs.taskOrdinal == rhs.taskOrdinal {
                    return lhs.emissionIndex < rhs.emissionIndex
                }
                return lhs.taskOrdinal < rhs.taskOrdinal
            }
            var current = try postGlobal.valueAny(for: spec.id)
            for write in ordered {
                current = try spec._reduceBox(current, write.value)
            }
            try postGlobal.setAny(current, for: spec.id)
            writtenGlobalChannels.append(spec.id)
        }

        var postTaskLocal: [HiveTaskLocalStore<Schema>] = []
        postTaskLocal.reserveCapacity(tasks.count)

        for (index, task) in tasks.enumerated() {
            var overlay = task.local
            let writes = perTaskWrites[index].taskLocal

            var writesByChannel: [HiveChannelID: [WriteRecord<Schema>]] = [:]
            for write in writes {
                writesByChannel[write.channelID, default: []].append(write)
            }

            for spec in registry.sortedChannelSpecs where spec.scope == .taskLocal {
                let channelWrites = writesByChannel[spec.id] ?? []
                if channelWrites.isEmpty { continue }
                if spec.updatePolicy == .single, channelWrites.count > 1 {
                    throw HiveRuntimeError.updatePolicyViolation(
                        channelID: spec.id,
                        policy: .single,
                        writeCount: channelWrites.count
                    )
                }
                let ordered = channelWrites.sorted { $0.emissionIndex < $1.emissionIndex }
                var current = try (overlay.valueAny(for: spec.id) ?? initialCache.valueAny(for: spec.id))
                for write in ordered {
                    current = try spec._reduceBox(current, write.value)
                }
                try overlay.setAny(current, for: spec.id)
            }
            postTaskLocal.append(overlay)
        }

        var nextGraphSeeds: [HiveTaskSeed<Schema>] = []
        var nextSpawnSeeds: [HiveTaskSeed<Schema>] = []

        for (index, task) in tasks.enumerated() {
            let output = outputs[index]
            if !output.spawn.isEmpty {
                nextSpawnSeeds.append(contentsOf: output.spawn)
            }

            let normalizedNext = output.next.normalized
            switch normalizedNext {
            case .useGraphEdges:
                break
            case .end:
                continue
            case .nodes(let nodes):
                for node in nodes {
                    nextGraphSeeds.append(HiveTaskSeed(nodeID: node))
                }
                continue
            }

            if let router = graph.routersByFrom[task.nodeID] {
                let routerGlobal = try applyGlobalWritesForTask(
                    taskIndex: index,
                    preStepGlobal: state.global,
                    perTaskWrites: perTaskWrites
                )
                let routerView = HiveStoreView(
                    global: routerGlobal,
                    taskLocal: postTaskLocal[index],
                    initialCache: initialCache,
                    registry: registry
                )
                let routed = router(routerView).normalized
                switch routed {
                case .useGraphEdges:
                    let staticEdges = graph.staticEdgesByFrom[task.nodeID] ?? []
                    for node in staticEdges {
                        nextGraphSeeds.append(HiveTaskSeed(nodeID: node))
                    }
                case .end:
                    break
                case .nodes(let nodes):
                    for node in nodes {
                        nextGraphSeeds.append(HiveTaskSeed(nodeID: node))
                    }
                }
            } else {
                let staticEdges = graph.staticEdgesByFrom[task.nodeID] ?? []
                for node in staticEdges {
                    nextGraphSeeds.append(HiveTaskSeed(nodeID: node))
                }
            }
        }

        var joinSeen = state.joinSeenParents
        for task in tasks {
            for edge in graph.joinEdges where edge.target == task.nodeID {
                let parentsSet = Set(edge.parents)
                if joinSeen[edge.id] == parentsSet {
                    joinSeen[edge.id] = []
                }
            }
        }

        for edge in graph.joinEdges {
            let parentsSet = Set(edge.parents)
            let wasAvailable = (joinSeen[edge.id] == parentsSet)
            var seen = joinSeen[edge.id] ?? []
            for task in tasks where parentsSet.contains(task.nodeID) {
                seen.insert(task.nodeID)
            }
            joinSeen[edge.id] = seen
            let isAvailable = (seen == parentsSet)
            if !wasAvailable && isAvailable {
                nextGraphSeeds.append(HiveTaskSeed(nodeID: edge.target))
            }
        }

        let dedupedGraphSeeds = try dedupeGraphSeeds(nextGraphSeeds, options: options)

        try validateSeedNodes(dedupedGraphSeeds, spawnSeeds: nextSpawnSeeds)

        var nextFrontier: [HiveFrontierTask<Schema>] = []
        nextFrontier.reserveCapacity(dedupedGraphSeeds.count + nextSpawnSeeds.count)
        for seed in dedupedGraphSeeds {
            nextFrontier.append(HiveFrontierTask(seed: seed, provenance: .graph))
        }
        for seed in nextSpawnSeeds {
            nextFrontier.append(HiveFrontierTask(seed: seed, provenance: .spawn))
        }

        return CommitResult(
            global: postGlobal,
            frontier: nextFrontier,
            joinSeenParents: joinSeen,
            writtenGlobalChannels: writtenGlobalChannels
        )
    }

    private func collectWrites(
        tasks: [HiveTask<Schema>],
        outputs: [HiveNodeOutput<Schema>]
    ) throws -> ([TaskWrites<Schema>], [HiveChannelID: [WriteRecord<Schema>]]) {
        var perTaskWrites: [TaskWrites<Schema>] = Array(repeating: TaskWrites(), count: tasks.count)
        var globalWritesByChannel: [HiveChannelID: [WriteRecord<Schema>]] = [:]

        for (taskIndex, output) in outputs.enumerated() {
            for (emissionIndex, write) in output.writes.enumerated() {
                guard let spec = registry.channelSpecsByID[write.channelID] else {
                    throw HiveRuntimeError.unknownChannelID(write.channelID)
                }
                try storeSupport.validateValueType(write.value, spec: spec)
                let record = WriteRecord(
                    channelID: write.channelID,
                    value: write.value,
                    emissionIndex: emissionIndex,
                    taskOrdinal: taskIndex,
                    spec: spec
                )
                switch spec.scope {
                case .global:
                    perTaskWrites[taskIndex].global.append(record)
                    globalWritesByChannel[write.channelID, default: []].append(record)
                case .taskLocal:
                    perTaskWrites[taskIndex].taskLocal.append(record)
                }
            }
        }

        return (perTaskWrites, globalWritesByChannel)
    }

    private func applyGlobalWritesForTask(
        taskIndex: Int,
        preStepGlobal: HiveGlobalStore<Schema>,
        perTaskWrites: [TaskWrites<Schema>]
    ) throws -> HiveGlobalStore<Schema> {
        var global = preStepGlobal
        let writes = perTaskWrites[taskIndex].global.sorted { $0.emissionIndex < $1.emissionIndex }
        if writes.isEmpty {
            return global
        }

        var writesByChannel: [HiveChannelID: [WriteRecord<Schema>]] = [:]
        for write in writes {
            writesByChannel[write.channelID, default: []].append(write)
        }

        for spec in registry.sortedChannelSpecs where spec.scope == .global {
            guard let channelWrites = writesByChannel[spec.id], !channelWrites.isEmpty else { continue }
            var current = try global.valueAny(for: spec.id)
            for write in channelWrites {
                current = try spec._reduceBox(current, write.value)
            }
            try global.setAny(current, for: spec.id)
        }

        return global
    }

    private func dedupeGraphSeeds(
        _ seeds: [HiveTaskSeed<Schema>],
        options: HiveRunOptions
    ) throws -> [HiveTaskSeed<Schema>] {
        var seen: Set<SeedKey> = []
        var deduped: [HiveTaskSeed<Schema>] = []
        deduped.reserveCapacity(seeds.count)

        for seed in seeds {
            let fingerprint = try HiveTaskLocalFingerprint.digest(
                registry: registry,
                initialCache: initialCache,
                overlay: seed.local,
                debugPayloads: options.debugPayloads
            )
            let key = SeedKey(nodeID: seed.nodeID, fingerprint: fingerprint)
            if seen.insert(key).inserted {
                deduped.append(seed)
            }
        }

        return deduped
    }

    private func validateSeedNodes(
        _ graphSeeds: [HiveTaskSeed<Schema>],
        spawnSeeds: [HiveTaskSeed<Schema>]
    ) throws {
        for seed in graphSeeds {
            guard graph.nodesByID[seed.nodeID] != nil else {
                throw HiveRuntimeError.unknownNodeID(seed.nodeID)
            }
        }
        for seed in spawnSeeds {
            guard graph.nodesByID[seed.nodeID] != nil else {
                throw HiveRuntimeError.unknownNodeID(seed.nodeID)
            }
        }
    }

    private func makeTaskID(
        runID: HiveRunID,
        stepIndex: Int,
        nodeID: HiveNodeID,
        ordinal: Int,
        localFingerprint: Data
    ) throws -> HiveTaskID {
        guard let stepValue = UInt32(exactly: stepIndex) else {
            throw HiveRuntimeError.stepIndexOutOfRange(stepIndex: stepIndex)
        }
        guard let ordinalValue = UInt32(exactly: ordinal) else {
            throw HiveRuntimeError.taskOrdinalOutOfRange(ordinal: ordinal)
        }
        guard localFingerprint.count == 32 else {
            preconditionFailure("Task local fingerprint must be 32 bytes.")
        }

        var bytes = Data()
        var uuid = runID.rawValue.uuid
        withUnsafeBytes(of: &uuid) { bytes.append(contentsOf: $0) }

        appendUInt32BE(stepValue, to: &bytes)
        bytes.append(0)
        bytes.append(contentsOf: nodeID.rawValue.utf8)
        bytes.append(0)
        appendUInt32BE(ordinalValue, to: &bytes)
        bytes.append(localFingerprint)

        let hash = SHA256.hash(data: bytes)
        let hex = hash.compactMap { String(format: "%02x", $0) }.joined()
        return HiveTaskID(hex)
    }

    private func payloadHash(for channelID: HiveChannelID, in global: HiveGlobalStore<Schema>) throws -> String {
        let spec = try storeSupport.requireSpec(for: channelID)
        let value = try global.valueAny(for: channelID)
        let bytes = try canonicalBytes(for: value, spec: spec)
        let hash = SHA256.hash(data: bytes)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func writeAppliedMetadata(
        for channelID: HiveChannelID,
        in global: HiveGlobalStore<Schema>,
        debugPayloads: Bool
    ) throws -> [String: String] {
        guard debugPayloads else { return [:] }
        let spec = try storeSupport.requireSpec(for: channelID)
        let value = try global.valueAny(for: channelID)

        var encoding: String = "unhashable"
        var payload: String = ""

        if let encode = spec._encodeBox {
            do {
                let data = try encode(value)
                encoding = "codec.base64"
                payload = data.base64EncodedString()
            } catch {
                if let json = try stableJSONDataIfEncodable(value) {
                    encoding = "json.utf8"
                    payload = String(decoding: json, as: UTF8.self)
                }
            }
        } else if let json = try stableJSONDataIfEncodable(value) {
            encoding = "json.utf8"
            payload = String(decoding: json, as: UTF8.self)
        }

        return [
            "valueTypeID": spec.valueTypeID,
            "codecID": spec.codecID ?? "",
            "payloadEncoding": encoding,
            "payload": payload
        ]
    }

    private func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private func canonicalBytes(for value: any Sendable, spec: AnyHiveChannelSpec<Schema>) throws -> Data {
        if let encode = spec._encodeBox {
            do {
                return try encode(value)
            } catch {
                if let json = try stableJSONDataIfEncodable(value) {
                    return json
                }
                return Data(("unhashable:" + spec.valueTypeID).utf8)
            }
        }

        if let json = try stableJSONDataIfEncodable(value) {
            return json
        }

        return Data(("unhashable:" + spec.valueTypeID).utf8)
    }

    private func stableJSONDataIfEncodable(_ value: any Sendable) throws -> Data? {
        guard let encodable = value as? any Encodable else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.dataEncodingStrategy = .base64
        return try encoder.encode(HiveAnyEncodable(encodable))
    }

    private struct HiveAnyEncodable: Encodable {
        let encodable: any Encodable

        init(_ encodable: any Encodable) {
            self.encodable = encodable
        }

        func encode(to encoder: Encoder) throws {
            try encodable.encode(to: encoder)
        }
    }

    private static func mapStream(_ kind: HiveStreamEventKind) -> HiveEventKind {
        switch kind {
        case .modelInvocationStarted(let model):
            return .modelInvocationStarted(model: model)
        case .modelToken(let text):
            return .modelToken(text: text)
        case .modelInvocationFinished:
            return .modelInvocationFinished
        case .toolInvocationStarted(let name):
            return .toolInvocationStarted(name: name)
        case .toolInvocationFinished(let name, let success):
            return .toolInvocationFinished(name: name, success: success)
        case .customDebug(let name):
            return .customDebug(name: name)
        }
    }
}

private struct HiveFrontierTask<Schema: HiveSchema>: Sendable {
    let seed: HiveTaskSeed<Schema>
    let provenance: HiveTaskProvenance
}

private struct ThreadState<Schema: HiveSchema>: Sendable {
    var runID: HiveRunID
    var stepIndex: Int
    var global: HiveGlobalStore<Schema>
    var frontier: [HiveFrontierTask<Schema>]
    var joinSeenParents: [String: Set<HiveNodeID>]
    var interruption: HiveInterrupt<Schema>?
    var latestCheckpointID: HiveCheckpointID?
}

private struct WriteRecord<Schema: HiveSchema>: Sendable {
    let channelID: HiveChannelID
    let value: any Sendable
    let emissionIndex: Int
    let taskOrdinal: Int
    let spec: AnyHiveChannelSpec<Schema>
}

private struct TaskWrites<Schema: HiveSchema>: Sendable {
    var global: [WriteRecord<Schema>] = []
    var taskLocal: [WriteRecord<Schema>] = []
}

private struct CommitResult<Schema: HiveSchema>: Sendable {
    let global: HiveGlobalStore<Schema>
    let frontier: [HiveFrontierTask<Schema>]
    let joinSeenParents: [String: Set<HiveNodeID>]
    let writtenGlobalChannels: [HiveChannelID]
}

private struct HiveDroppedEventCounts: Sendable {
    var droppedModelTokenEvents: Int = 0
    var droppedDebugEvents: Int = 0

    mutating func record(_ enqueueResult: HiveEventEnqueueResult) {
        switch enqueueResult {
        case .droppedModelToken:
            droppedModelTokenEvents += 1
        case .droppedDebug:
            droppedDebugEvents += 1
        case .enqueued, .coalescedModelToken, .terminated:
            break
        }
    }
}

private final class HiveDroppedEventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = HiveDroppedEventCounts()

    func record(_ enqueueResult: HiveEventEnqueueResult) {
        lock.lock()
        counts.record(enqueueResult)
        lock.unlock()
    }

    func snapshot() -> HiveDroppedEventCounts {
        lock.lock()
        let snapshot = counts
        lock.unlock()
        return snapshot
    }
}

private struct BufferedStreamEvent: Sendable {
    let kind: HiveEventKind
    let metadata: [String: String]
    let taskOrdinal: Int
}

private final class HivePerAttemptStreamBuffer: @unchecked Sendable {
    private let capacity: Int
    private let stepIndex: Int
    private let taskOrdinal: Int
    private let lock = NSLock()

    private var events: [BufferedStreamEvent] = []
    private var dropped = HiveDroppedEventCounts()
    private var overflowError: Error?

    init(capacity: Int, stepIndex: Int, taskOrdinal: Int) {
        self.capacity = max(1, capacity)
        self.stepIndex = stepIndex
        self.taskOrdinal = taskOrdinal
        self.events.reserveCapacity(min(8, self.capacity))
    }

    func record(kind: HiveEventKind, metadata: [String: String]) {
        lock.lock()
        defer { lock.unlock() }

        guard overflowError == nil else { return }

        if events.count < capacity {
            events.append(BufferedStreamEvent(kind: kind, metadata: metadata, taskOrdinal: taskOrdinal))
            return
        }

        switch kind {
        case .modelToken(let text):
            if let last = events.last, case let .modelToken(existing) = last.kind {
                events[events.count - 1] = BufferedStreamEvent(
                    kind: .modelToken(text: existing + text),
                    metadata: last.metadata,
                    taskOrdinal: taskOrdinal
                )
            } else {
                dropped.droppedModelTokenEvents += 1
            }
        case .customDebug:
            dropped.droppedDebugEvents += 1
        default:
            overflowError = HiveRuntimeError.modelStreamInvalid(
                "Non-droppable stream event buffer overflow (stepIndex=\(stepIndex), taskOrdinal=\(taskOrdinal), perTaskCapacity=\(capacity))"
            )
        }
    }

    func snapshot() -> (events: [BufferedStreamEvent], dropped: HiveDroppedEventCounts, overflowError: Error?) {
        lock.lock()
        let snapshot = (events: events, dropped: dropped, overflowError: overflowError)
        lock.unlock()
        return snapshot
    }
}

private struct TaskExecutionResult<Schema: HiveSchema>: @unchecked Sendable {
    let output: HiveNodeOutput<Schema>?
    let error: Error?
    let streamEvents: [BufferedStreamEvent]?
    let streamDrops: HiveDroppedEventCounts

    static var empty: TaskExecutionResult<Schema> {
        TaskExecutionResult(output: nil, error: nil, streamEvents: nil, streamDrops: .init())
    }

    init(
        output: HiveNodeOutput<Schema>?,
        error: Error?,
        streamEvents: [BufferedStreamEvent]?,
        streamDrops: HiveDroppedEventCounts
    ) {
        self.output = output
        self.error = error
        self.streamEvents = streamEvents
        self.streamDrops = streamDrops
    }

    init(output: HiveNodeOutput<Schema>, streamEvents: [BufferedStreamEvent], streamDrops: HiveDroppedEventCounts) {
        self.output = output
        self.error = nil
        self.streamEvents = streamEvents
        self.streamDrops = streamDrops
    }

    init(error: Error) {
        self.output = nil
        self.error = error
        self.streamEvents = nil
        self.streamDrops = .init()
    }
}

private struct SeedKey: Hashable, Sendable {
    let nodeID: HiveNodeID
    let fingerprint: Data
}

private final class HiveEventEmitter: @unchecked Sendable {
    private let runID: HiveRunID
    private let attemptID: HiveRunAttemptID
    private let streamController: HiveEventStreamController
    private var eventIndex: UInt64 = 0
    private let lock = NSLock()

    init(
        runID: HiveRunID,
        attemptID: HiveRunAttemptID,
        streamController: HiveEventStreamController
    ) {
        self.runID = runID
        self.attemptID = attemptID
        self.streamController = streamController
    }

    @discardableResult
    func emit(
        kind: HiveEventKind,
        stepIndex: Int?,
        taskOrdinal: Int?,
        metadata: [String: String] = [:]
    ) -> HiveEventEnqueueResult {
        lock.lock()
        let nextIndex = eventIndex
        let result = streamController.enqueue(
            eventIndex: nextIndex,
            runID: runID,
            attemptID: attemptID,
            kind: kind,
            stepIndex: stepIndex,
            taskOrdinal: taskOrdinal,
            metadata: metadata
        )
        if case .enqueued = result {
            eventIndex += 1
        }
        lock.unlock()
        return result
    }
}
