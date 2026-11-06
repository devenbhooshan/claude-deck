#!/bin/bash
# Builds a signed, notarized Claude-Deck-<version>.dmg in ./build, ready to publish.
#
# Needs, once per Mac:
#   1. A "Developer ID Application" certificate in your login keychain (developer.apple.com → Certificates).
#   2. Notarization credentials stored in your keychain under a profile name (default "nook-notary"):
#        xcrun notarytool store-credentials nook-notary --apple-id you@example.com --team-id TEAMID
#      It asks for an app-specific password (appleid.apple.com → Sign-In and Security → App-Specific Passwords).
#
# Nothing here is specific to one maintainer: override with DECK_SIGN_IDENTITY and DECK_NOTARY_PROFILE.
set -euo pipefail
cd "$(dirname "$0")/.."

identity="${DECK_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')}"
profile="${DECK_NOTARY_PROFILE:-nook-notary}"
if [[ -z "$identity" ]]; then
    echo "No \"Developer ID Application\" certificate found in your keychain. See the comment at the top of this script." >&2
    exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Info.plist)"
echo "Releasing Claude Deck $version, signed as: $identity"

./test.sh
./build.sh >/dev/null

app="build/Claude Deck.app"
# Inside out: the helpers, then the app. Hardened runtime and a secure timestamp are required for notarization.
for helper in deck-policy deck-routine; do
    codesign --force --options runtime --timestamp --identifier "$bundle_id.$helper" --sign "$identity" "$app/Contents/MacOS/$helper"
done
codesign --force --options runtime --timestamp --entitlements ClaudeDeck.entitlements --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

dmg="build/Claude-Deck-$version.dmg"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -volname "Claude Deck" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null
codesign --force --timestamp --sign "$identity" "$dmg"

echo "Submitting to Apple for notarization (usually a few minutes)…"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"
xcrun stapler staple "$app"

spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
echo "Done: $dmg"
