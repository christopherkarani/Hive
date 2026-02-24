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

FULL_SUITE_TIMEOUT_SECONDS="${HIVE_FULL_SUITE_TIMEOUT_SECONDS:-600}"
RUN_LOG_FILE="${HIVE_FULL_SUITE_LOG_FILE:-${TMPDIR:-/tmp}/hive-full-suite.log}"
FALLBACK_STABLE="${HIVE_FULL_SUITE_FALLBACK_STABLE:-1}"

if ! [[ "$FULL_SUITE_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$FULL_SUITE_TIMEOUT_SECONDS" -le 0 ]]; then
  echo "[full-suite] HIVE_FULL_SUITE_TIMEOUT_SECONDS must be a positive integer."
  exit 1
fi

run_full_suite_with_timeout() {
  local pid=""
  local watcher_pid=""
  local timeout_marker="${RUN_LOG_FILE}.timeout"
  rm -f "$RUN_LOG_FILE" "$timeout_marker"

  swift test --disable-sandbox >"$RUN_LOG_FILE" 2>&1 &
  pid="$!"

  (
    sleep "$FULL_SUITE_TIMEOUT_SECONDS"
    if kill -0 "$pid" 2>/dev/null; then
      echo "[full-suite] Timeout after ${FULL_SUITE_TIMEOUT_SECONDS}s." | tee -a "$RUN_LOG_FILE"
      echo "timeout" > "$timeout_marker"
      kill "$pid" 2>/dev/null || true
      pkill -P "$pid" 2>/dev/null || true
      sleep 3
      kill -9 "$pid" 2>/dev/null || true
      pkill -9 -P "$pid" 2>/dev/null || true
      pkill -f "swiftpm-testing-helper --test-bundle-path ${ROOT_DIR}/.build/arm64-apple-macosx/debug/HivePackageTests.xctest/Contents/MacOS/HivePackageTests" 2>/dev/null || true
    fi
  ) &
  watcher_pid="$!"

  local status=0
  if wait "$pid"; then
    status=0
  else
    status=$?
  fi

  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true

  if [[ -f "$timeout_marker" ]]; then
    rm -f "$timeout_marker"
    return 124
  fi

  return "$status"
}

emit_stall_diagnostics() {
  echo "[full-suite] Stall diagnostics:"
  echo "[full-suite] Last started tests:"
  rg -n "Test \".*\" started\\.$" "$RUN_LOG_FILE" | tail -n 20 || true
  echo "[full-suite] Last completed tests:"
  rg -n "Test \".*\" passed after|Test \".*\" failed after" "$RUN_LOG_FILE" | tail -n 20 || true
  echo "[full-suite] Active swift test processes:"
  ps -Ao pid,ppid,state,%cpu,etime,command 2>/dev/null | rg "swift test --disable-sandbox|swiftpm-testing-helper --test-bundle-path .*HivePackageTests" || true
}

echo "[full-suite] Running full package test suite..."
if run_full_suite_with_timeout; then
  tail -n 120 "$RUN_LOG_FILE" || true
  echo "[full-suite] Passed."
  exit 0
else
  status=$?
  if [[ "$status" -eq 124 ]]; then
    emit_stall_diagnostics
    if [[ "$FALLBACK_STABLE" == "1" ]]; then
      echo "[full-suite] Falling back to isolated stable runner..."
      ./scripts/swift-test-stable.sh
      echo "[full-suite] Passed via stable fallback."
      exit 0
    fi
  else
    echo "[full-suite] swift test failed with status ${status}. Recent log output:"
    tail -n 120 "$RUN_LOG_FILE" || true
  fi

  exit "$status"
fi
