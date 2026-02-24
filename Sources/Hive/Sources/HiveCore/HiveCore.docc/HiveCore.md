# ``HiveCore``

Zero-dependency core runtime for deterministic agent workflow execution.

@Metadata {
    @DisplayName("HiveCore")
}

## Overview

HiveCore provides the schema system, graph compiler, store model, and superstep runtime that power Hive's deterministic workflow execution. It has zero external dependencies — pure Swift built on actors and structured concurrency.

HiveCore is organized into focused subsystems:

| Subsystem | Responsibility |
|-----------|---------------|
| Schema | Channel specs, keys, reducers, codecs, schema registry, type erasure |
| Store | Global store, task-local store, store view, initial cache, fingerprinting |
| Graph | Graph builder, compile, validation, versioning, Mermaid export |
| Runtime | Superstep execution, frontier computation, event streaming, interrupts, retry |
| Checkpointing | Checkpoint format, store protocol, policies |
| Hybrid Inference | Model client, ReAct loop, tool registry, streaming |
| Memory | Memory store protocol, in-memory implementation |

## Topics

### Essentials

- <doc:DefiningASchema>
- <doc:UnderstandingTheStore>
- <doc:BuildingGraphs>
- <doc:RuntimeExecution>

### Schema

- ``HiveSchema``
- ``HiveChannelSpec``
- ``HiveChannelKey``
- ``HiveChannelID``
- ``HiveChannelScope``
- ``HiveChannelPersistence``
- ``HiveReducer``
- ``HiveCodec``
- ``HiveJSONCodec``
- ``HiveAnyCodec``
- ``AnyHiveChannelSpec``
- ``HiveUpdatePolicy``

### Store

- ``HiveGlobalStore``
- ``HiveTaskLocalStore``
- ``HiveStoreView``
- ``HiveSchemaRegistry``

### Graph

- ``HiveGraphBuilder``
- ``CompiledHiveGraph``
- ``HiveGraphDescription``
- ``HiveGraphMermaidExporter``
- ``HiveNodeID``

### Runtime

- <doc:RuntimeExecution>
- <doc:CheckpointingAndResume>
- ``HiveRuntime``
- ``HiveEnvironment``
- ``HiveRunHandle``
- ``HiveRunOutcome``
- ``HiveRunOptions``
- ``HiveRunOutput``
- ``HiveRunID``
- ``HiveThreadID``
- ``HiveEvent``
- ``HiveRetryPolicy``

### Checkpointing

- <doc:CheckpointingAndResume>
- ``HiveCheckpoint``
- ``HiveCheckpointID``
- ``HiveCheckpointStore``
- ``HiveCheckpointPolicy``
- ``HiveCheckpointQueryableStore``

### Interrupts

- ``HiveInterruptRequest``
- ``HiveInterrupt``
- ``HiveResume``
- ``HiveInterruption``

### Hybrid Inference

- <doc:HybridInference>
- ``HiveModelClient``
- ``HiveChatRequest``
- ``HiveChatResponse``
- ``HiveChatMessage``
- ``HiveChatRole``
- ``HiveChatStreamChunk``
- ``HiveToolDefinition``
- ``HiveToolCall``
- ``HiveToolResult``
- ``HiveToolRegistry``
- ``HiveModelToolLoop``

### Memory

- ``HiveMemoryStore``
- ``HiveMemoryItem``
- ``InMemoryHiveMemoryStore``

### Errors

- ``HiveRuntimeError``
- ``HiveCompilationError``
- ``HiveCheckpointQueryError``

### Advanced

- <doc:DeterminismGuarantees>
