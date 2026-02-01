Prompt:
Vendor the minimal TiktokenSwift sources/binary into the codebase to eliminate the external dependency.

Goal:
Make Wax’s token counting buildable without external Git LFS dependencies while keeping API behavior stable.

Task BreakDown
- Inspect TiktokenSwift package to identify the minimal surface required (`CoreBpe`, `EncodingLoader`, related resources).
- Decide whether to vendor the binary `TiktokenFFI.xcframework` or rebuild from source.
- If vendoring the xcframework, ensure its LFS objects are present, copy into a new local target (e.g., `WaxTiktoken`), and update `rag/Wax/Package.swift` to use a local binary target.
- If rebuilding from source, set up a build script to produce the xcframework and commit it to the repo (or host internally).
- Update `TokenCounter` and any imports to reference the new local module.
- Add/adjust Swift Testing tests to validate tokenization parity.
- Remove the external dependency on `https://github.com/narner/TiktokenSwift.git`.
