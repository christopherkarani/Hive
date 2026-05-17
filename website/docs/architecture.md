---
title: Architecture
description: Hive package and runtime architecture.
---

# Architecture

Hive exposes one package-level runtime import plus the underlying core module:

```text
Hive      package-level runtime import; re-exports HiveCore
HiveCore  schemas, graph compiler, runtime, events, checkpoint protocols
```

`HiveCore` owns the execution model:

| Area | Responsibility |
| --- | --- |
| Schema | Channel IDs, scopes, reducers, codecs, update policies |
| Graph | Nodes, static edges, routers, joins, output projection |
| Runtime | Supersteps, retries, cancellation, interrupts, resume, fork |
| Store | Global and task-local state views |
| Checkpointing | Protocols, checkpoint payloads, query helpers |
| Events | Run, step, task, write, checkpoint, snapshot, update, debug events |

The package intentionally does not include a workflow DSL, model/tool calling APIs, RAG memory, or provider adapters.
