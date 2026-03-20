# Hive Examples

These runnable SwiftPM examples target Apple platforms and focus on the core Hive execution model.

## Tiny Graph (Send + Interrupt/Resume)

This example shows:
- A small graph with fan-out via `spawn`
- Task-local payloads passed to workers
- Interrupt and resume with checkpointing

Run (macOS):
```sh
cd libs/hive
swift run HiveTinyGraphExample
```

Run (Xcode):
```sh
open libs/hive/Package.swift
```
Select the `HiveTinyGraphExample` scheme and run on macOS. To run on iOS, embed the example code in an app target and use an iOS simulator.

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
