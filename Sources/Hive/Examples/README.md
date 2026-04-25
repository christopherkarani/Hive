# Hive Examples

These runnable SwiftPM examples focus on the core Hive graph runtime.

## Tiny Graph (Send + Interrupt/Resume)

This example shows:
- A small graph with fan-out via `spawn`
- Task-local payloads passed to workers
- Interrupt and resume with checkpointing

Run:
```sh
swift run HiveTinyGraphExample
```

Expected output (shape):
```text
Starting run...
Gate sees results: ["WorkerA processed apple", "WorkerB processed banana"]
Interrupted with payload: review
Resuming...
Finalize resume payload: approved
Finalize results: ["WorkerA processed apple", "WorkerB processed banana"]
Final results: ["WorkerA processed apple", "WorkerB processed banana"]
```
