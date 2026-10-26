#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/manting-timeline.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$TEST_DIR/module-cache" "$PROJECT_DIR/Sources/SpeechTimeline.swift" "$PROJECT_DIR/Tests/TimelineTests.swift" -o "$TEST_DIR/timeline-tests"
"$TEST_DIR/timeline-tests"
