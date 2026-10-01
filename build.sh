#!/bin/bash
# Builds Claude Deck.app into ./build and optionally installs it to /Applications (pass --install).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/"Claude Deck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClaudeDeck "$APP/Contents/MacOS/ClaudeDeck"
cp Info.plist "$APP/Contents/Info.plist"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"
if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/Claude Deck.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Claude Deck.app"
fi
