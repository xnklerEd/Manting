#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/manting-reading.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$PROJECT_DIR/build/ModuleCache" \
    "$PROJECT_DIR/Sources/PinyinAnnotation.swift" "$PROJECT_DIR/Sources/ReadingLayout.swift" \
    "$PROJECT_DIR/Tests/ReadingTests.swift" -o "$TEST_DIR/reading-tests" -framework AppKit -framework JavaScriptCore
"$TEST_DIR/reading-tests" "$PROJECT_DIR/Resources/pinyin-pro-3.29.4.js"
