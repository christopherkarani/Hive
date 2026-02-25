#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LIST_FILE="${TMPDIR:-/tmp}/hive-test-specifiers.txt"
FAILURES_FILE="${TMPDIR:-/tmp}/hive-test-failures.txt"
HANGS_FILE="${TMPDIR:-/tmp}/hive-test-hangs.txt"
RUN_LOG_FILE="${TMPDIR:-/tmp}/hive-test-run.log"
rm -f "$LIST_FILE" "$FAILURES_FILE" "$HANGS_FILE"

export HOME="$ROOT_DIR/.build/swift-home"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"
mkdir -p \
  "$HOME/Library/Caches/org.swift.swiftpm" \
  "$HOME/Library/org.swift.swiftpm/configuration" \
  "$HOME/Library/org.swift.swiftpm/security" \
  "$CLANG_MODULE_CACHE_PATH"

TEST_TIMEOUT_SECONDS="${HIVE_STABLE_TEST_TIMEOUT_SECONDS:-120}"

if ! [[ "$TEST_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$TEST_TIMEOUT_SECONDS" -le 0 ]]; then
    echo "[stable-test] HIVE_STABLE_TEST_TIMEOUT_SECONDS must be a positive integer."
    exit 1
fi

run_one_test() {
    local filter_regex="$1"
    local log_file="$2"
    local pid=""
    local watcher_pid=""
    local timeout_marker="${log_file}.timeout"
    rm -f "$timeout_marker"

    swift test --disable-sandbox --skip-build --filter "$filter_regex" >"$log_file" 2>&1 &
    pid="$!"

    (
        sleep "$TEST_TIMEOUT_SECONDS"
        if kill -0 "$pid" 2>/dev/null; then
            echo "[stable-test] Timeout after ${TEST_TIMEOUT_SECONDS}s for filter: ${filter_regex}" >"$timeout_marker"
            kill "$pid" 2>/dev/null || true
            pkill -P "$pid" 2>/dev/null || true
            sleep 2
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
        cat "$timeout_marker"
        rm -f "$timeout_marker"
        return 124
    fi

    return "$status"
}

echo "[stable-test] Discovering tests..."
swift test --disable-sandbox list | awk '/^[A-Za-z0-9_]+\./ { print }' > "$LIST_FILE"

TOTAL_TESTS="$(wc -l < "$LIST_FILE" | tr -d ' ')"
if [[ "$TOTAL_TESTS" -eq 0 ]]; then
    echo "[stable-test] No tests discovered."
    exit 1
fi

LIMIT="${HIVE_STABLE_TEST_LIMIT:-}"
if [[ -n "${LIMIT}" ]]; then
    if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [[ "$LIMIT" -le 0 ]]; then
        echo "[stable-test] HIVE_STABLE_TEST_LIMIT must be a positive integer."
        exit 1
    fi
    head -n "$LIMIT" "$LIST_FILE" > "${LIST_FILE}.tmp"
    mv "${LIST_FILE}.tmp" "$LIST_FILE"
    TOTAL_TESTS="$(wc -l < "$LIST_FILE" | tr -d ' ')"
fi

echo "[stable-test] Running ${TOTAL_TESTS} tests in isolated invocations..."
echo "[stable-test] Per-test timeout: ${TEST_TIMEOUT_SECONDS}s"

index=0
while IFS= read -r specifier; do
    index=$((index + 1))
    echo "[stable-test] (${index}/${TOTAL_TESTS}) ${specifier}"

    # `swift test list` includes module/suite prefixes and trailing `()`.
    # `--filter` works reliably with the concrete test function identifier.
    filter_term="${specifier%()}"
    if [[ "$filter_term" == */* ]]; then
        filter_term="${filter_term##*/}"
    else
        filter_term="${filter_term##*.}"
    fi

    # --filter expects a regex; escape regex metacharacters.
    escaped_filter="$(printf '%s' "$filter_term" | sed -E 's/[][(){}.+*?^$|\\/]/\\&/g')"

    if run_one_test "${escaped_filter}" "$RUN_LOG_FILE"; then
        :
    else
        status=$?
        echo "$specifier" >> "$FAILURES_FILE"
        if [[ "$status" -eq 124 ]]; then
            echo "$specifier" >> "$HANGS_FILE"
            echo "[stable-test] Hung test detected: $specifier"
        fi
        echo "[stable-test] Last log lines for ${specifier}:"
        tail -n 40 "$RUN_LOG_FILE" || true
        continue
    fi

    if grep -q "No matching test cases were run" "$RUN_LOG_FILE"; then
        echo "$specifier" >> "$FAILURES_FILE"
    fi
done < "$LIST_FILE"

if [[ -f "$FAILURES_FILE" ]]; then
    if [[ -f "$HANGS_FILE" ]]; then
        echo "[stable-test] Hung tests (timed out):"
        cat "$HANGS_FILE"
    fi
    echo "[stable-test] Failed tests:"
    cat "$FAILURES_FILE"
    exit 1
fi

echo "[stable-test] All tests passed."
