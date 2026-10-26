#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/build/慢听.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$PROJECT_DIR/build/ModuleCache"
if [ ! -f "$PROJECT_DIR/build/AppIcon.icns" ]; then
  xcrun swift -module-cache-path "$PROJECT_DIR/build/ModuleCache" "$PROJECT_DIR/scripts/make-icon.swift" "$PROJECT_DIR/build/AppIcon.iconset"
  iconutil -c icns "$PROJECT_DIR/build/AppIcon.iconset" -o "$PROJECT_DIR/build/AppIcon.icns"
fi
cp "$PROJECT_DIR/build/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Resources/pinyin-pro-3.29.4.js" "$APP_DIR/Contents/Resources/"
cp "$PROJECT_DIR/Resources/pinyin-pro-LICENSE.txt" "$APP_DIR/Contents/Resources/"
xcrun swiftc -swift-version 5 -parse-as-library -O -suppress-warnings -module-cache-path "$PROJECT_DIR/build/ModuleCache" -target arm64-apple-macosx14.0 "$PROJECT_DIR/Sources/SpeechTimeline.swift" "$PROJECT_DIR/scripts/SpeechHelper.swift" -o "$APP_DIR/Contents/MacOS/MantingSpeechHelper" -framework AppKit -framework AVFoundation
xcrun swiftc -swift-version 5 -parse-as-library -O -module-cache-path "$PROJECT_DIR/build/ModuleCache" -target arm64-apple-macosx14.0 "$PROJECT_DIR"/Sources/*.swift -o "$APP_DIR/Contents/MacOS/Manting" -framework AppKit -framework SwiftUI -framework AVFoundation -framework MediaPlayer -framework JavaScriptCore
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>慢听</string>
<key>CFBundleDisplayName</key><string>慢听</string>
<key>CFBundleIdentifier</key><string>local.cw.manting</string>
<key>CFBundleVersion</key><string>9</string>
<key>CFBundleShortVersionString</key><string>1.4.2</string>
<key>CFBundleExecutable</key><string>Manting</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticTermination</key><false/>
</dict></plist>
PLIST
if [ -f "$PROJECT_DIR/THIRD_PARTY_NOTICES.txt" ]; then cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.txt" "$APP_DIR/Contents/Resources/"; fi
codesign --force --sign - "$APP_DIR/Contents/MacOS/MantingSpeechHelper"
codesign --force --sign - "$APP_DIR"
printf '%s\n' "$APP_DIR"
