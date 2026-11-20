#!/bin/sh
# Builds build/screc.app, and with "dmg" also build/screc.dmg, the disk image to install it from.
#
#   Packaging/build-app.sh [dmg]
#
# Settings, from the environment:
#   VERSION        version shown in Finder (default: 0.1.1)
#   BUNDLE_ID      bundle identifier (default: io.github.tatsukawa.screc; give your own builds your own
#                  reverse-DNS name if you distribute them)
#   SIGN_IDENTITY  codesign identity (default: "-", an ad-hoc signature, enough for your own Mac;
#                  use a "Developer ID Application" identity to distribute, then notarize the DMG)
set -eu
cd "$(dirname "$0")/.."

VERSION=${VERSION:-0.1.1}
BUNDLE_ID=${BUNDLE_ID:-io.github.tatsukawa.screc}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

# One binary for both Apple silicon and Intel Macs.
swift build -c release --arch arm64 --arch x86_64
BINARY="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/screc"

APP=build/screc.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/screc"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    Packaging/Info.plist > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"

# The icon is an Icon Composer document: macOS 26 and later draw it as Liquid Glass from Assets.car, adapting it to
# light, dark and tinted appearances, and actool also renders AppIcon.icns for macOS 15 to 25.
# (actool insists on writing the Info.plist keys it wants; Packaging/Info.plist already has them.)
PARTIAL_PLIST=$(mktemp -t screc-icon)
xcrun actool Packaging/AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon --platform macosx \
    --target-device mac --minimum-deployment-target 15.0 --output-partial-info-plist "$PARTIAL_PLIST" >/dev/null
rm -f "$PARTIAL_PLIST"

codesign --force --options runtime --entitlements Packaging/screc.entitlements --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION, $BUNDLE_ID)"

if [ "${1:-}" = "dmg" ]; then
    # The usual installer: the app next to a link to /Applications, to drag it onto.
    rm -rf build/dmg build/screc.dmg
    mkdir -p build/dmg
    cp -R "$APP" build/dmg/
    ln -s /Applications build/dmg/Applications
    hdiutil create -quiet -volname screc -srcfolder build/dmg -fs HFS+ -format UDZO build/screc.dmg
    rm -rf build/dmg
    codesign --force --sign "$SIGN_IDENTITY" build/screc.dmg
    echo "Built build/screc.dmg"
fi
