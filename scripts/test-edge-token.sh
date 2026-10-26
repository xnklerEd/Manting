#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d -t manting-edge-token)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 5 -parse-as-library \
  -module-cache-path "$TEST_DIR/module-cache" \
  "$PROJECT_DIR/Sources/EdgeToken.swift" "$PROJECT_DIR/Tests/EdgeTokenTests.swift" \
  -o "$TEST_DIR/edge-token-tests"
"$TEST_DIR/edge-token-tests"
