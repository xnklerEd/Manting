#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/manting-core.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "$TEST_DIR/module-cache" \
  "$PROJECT_DIR/Sources/Core.swift" "$PROJECT_DIR/Tests/CoreTests.swift" \
  -o "$TEST_DIR/core-tests"
"$TEST_DIR/core-tests"
