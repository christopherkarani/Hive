#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export HOME="$ROOT_DIR/.build/swift-home"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"
mkdir -p \
  "$HOME/Library/Caches/org.swift.swiftpm" \
  "$HOME/Library/org.swift.swiftpm/configuration" \
  "$HOME/Library/org.swift.swiftpm/security" \
  "$CLANG_MODULE_CACHE_PATH"

echo "[contract-suite] Running Swarm contract/runtime tests..."
swift test --disable-sandbox --filter "HiveCheckpointQueryTests|HiveRuntimeSwarmContractTests|HiveRuntimeCheckpointTests|HiveRuntimeInterruptResumeExternalWritesTests|HiveRuntimeErrorsRetriesCancellationLimitsTests"

echo "[contract-suite] Passed."
