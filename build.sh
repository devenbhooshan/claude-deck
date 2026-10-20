#!/bin/bash
# Builds Claude Deck.app into ./build and optionally installs it to /Applications (pass --install).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
# The policy checker Claude Code runs before each tool call: small, so it starts in a few ms.
swiftc -O -o .build/release/deck-policy Sources/ClaudeDeck/Core/Policies.swift Sources/PolicyCheck/main.swift
APP=build/"Claude Deck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClaudeDeck "$APP/Contents/MacOS/ClaudeDeck"
cp .build/release/deck-policy "$APP/Contents/MacOS/deck-policy"
cp Info.plist "$APP/Contents/Info.plist"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"
if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/Claude Deck.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Claude Deck.app"
fi
