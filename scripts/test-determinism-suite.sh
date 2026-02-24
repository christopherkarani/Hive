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

echo "[determinism-suite] Running deterministic transcript/state hash checks..."
swift test --disable-sandbox --filter "HiveRuntimeDeterminismSoakTests|transcript hashing is deterministic across identical runs"

echo "[determinism-suite] Passed."
