#!/bin/zsh
# Builds Screenme (Release), signs it with a stable local identity and installs it in /Applications.
#
# macOS ties Screen Recording and the other privacy permissions to the app's signature.
# An ad-hoc signature changes on every build, so each new build lost the permissions.
# A self-signed certificate keeps the same identity across builds: grant once, keep it.
# The certificate lives in its own keychain, so the login keychain and trust settings stay untouched.
set -euo pipefail

ROOT="${0:A:h:h}"
IDENTITY="Screenme Local Signing"
KEYCHAIN="$HOME/Library/Keychains/screenme-signing.keychain-db"
KEYCHAIN_PASSWORD="screenme-local-signing" # protects only this self-signed key

if [[ ! -f "$KEYCHAIN" ]]; then
  echo "Creating the signing identity \"$IDENTITY\"…"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  /opt/homebrew/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$IDENTITY" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null
  /opt/homebrew/bin/openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -out "$tmp/identity.p12" -passout pass:screenme
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN" # never auto-lock
  security import "$tmp/identity.p12" -k "$KEYCHAIN" -P screenme -T /usr/bin/codesign
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
fi
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

cd "$ROOT"
xcodegen generate >/dev/null
xcodebuild -project Screenme.xcodeproj -scheme Screenme -configuration Release \
  -derivedDataPath build/release build -quiet
APP="build/release/Build/Products/Release/Screenme.app"
# Check for Updates in the app reads where it was built from and which commit it is.
plutil -replace ScreenmeSourcePath -string "$ROOT" "$APP/Contents/Info.plist"
plutil -replace ScreenmeCommit -string "$(git -C "$ROOT" rev-parse HEAD)" "$APP/Contents/Info.plist"
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --preserve-metadata=entitlements,flags "$APP"
codesign --verify --strict "$APP"

pkill -x Screenme 2>/dev/null && sleep 1 || true
rm -rf /Applications/Screenme.app
cp -R "$APP" /Applications/
open /Applications/Screenme.app
echo "Installed: $(codesign -d -r- /Applications/Screenme.app 2>&1 | grep designated)"
