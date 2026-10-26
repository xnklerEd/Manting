#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$PROJECT_DIR/build/ModuleCache"
xcrun swiftc -swift-version 5 -parse-as-library -suppress-warnings -module-cache-path "$PROJECT_DIR/build/ModuleCache" "$PROJECT_DIR/Sources/SpeechTimeline.swift" "$PROJECT_DIR/scripts/SpeechHelper.swift" -o "$PROJECT_DIR/build/MantingSpeechHelper" -framework AppKit -framework AVFoundation
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$PROJECT_DIR/build/ModuleCache" "$PROJECT_DIR/Sources/Core.swift" "$PROJECT_DIR/Sources/TextSearch.swift" "$PROJECT_DIR/Sources/SpeechTimeline.swift" "$PROJECT_DIR/Sources/DeletionStore.swift" "$PROJECT_DIR/Sources/SpeechService.swift" "$PROJECT_DIR/Sources/PlayerModel.swift" "$PROJECT_DIR/Tests/PlaybackTests.swift" -o "$PROJECT_DIR/build/PlaybackTests" -framework AppKit -framework AVFoundation -framework MediaPlayer
"$PROJECT_DIR/build/PlaybackTests" "$@"
