**Hive Examples**

[![Discord](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fdiscord.com%2Fapi%2Fv10%2Finvites%2FNHgNh7HJ6M%3Fwith_counts%3Dtrue&query=%24.approximate_presence_count&suffix=%20online&logo=discord&label=Discord&color=5865F2)](https://discord.gg/NHgNh7HJ6M)
These runnable SwiftPM examples target Apple platforms (macOS/iOS) and focus on core Hive semantics.

**Tiny Graph (Send + Interrupt/Resume)**
This example demonstrates:
- A tiny graph with fan-out via `spawn` (Send)
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
