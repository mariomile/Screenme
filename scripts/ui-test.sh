#!/bin/zsh
# Runs the end-to-end UI tests against a Debug build signed like the installed app,
# so the Screen Recording permission granted to /Applications/Screenme.app applies to it too.
# The installed Screenme is quit for the run (one set of shortcuts and menu bar icons) and reopened after.
# Pass extra xcodebuild arguments, e.g. -only-testing:ScreenmeUITests/CaptureUITests.
set -euo pipefail

ROOT="${0:A:h:h}"
IDENTITY="Screenme Local Signing"
KEYCHAIN="$HOME/Library/Keychains/screenme-signing.keychain-db"
DERIVED="build/uitests"

[[ -f "$KEYCHAIN" ]] || { echo "Run scripts/install.sh once first: it creates the signing identity."; exit 1; }
security unlock-keychain -p "screenme-local-signing" "$KEYCHAIN"

cd "$ROOT"
xcodegen generate >/dev/null
xcodebuild build-for-testing -project Screenme.xcodeproj -scheme Screenme -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" -quiet
APP="$DERIVED/Build/Products/Debug/Screenme.app"
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --preserve-metadata=entitlements,flags "$APP"
# Xcode sandboxes the test runner; the tests read the captures Screenme writes in ~/Library/Application Support.
codesign --force --sign - "$DERIVED/Build/Products/Debug/ScreenmeUITests-Runner.app"

reopen() { open /Applications/Screenme.app 2>/dev/null || true; }
trap reopen EXIT
pkill -x Screenme 2>/dev/null && sleep 1 || true

xcodebuild test-without-building -project Screenme.xcodeproj -scheme Screenme -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" -only-testing:ScreenmeUITests "$@"
