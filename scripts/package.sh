#!/bin/bash
# Yayın paketlerini üretir: dist/Pusu-<sürüm>.zip, .dmg ve SHA256SUMS.
#
#   scripts/package.sh
#
# İsteğe bağlı (Apple Developer ID varsa):
#   PUSU_SIGN_IDENTITY="Developer ID Application: Ad Soyad (TEAMID)"
#   PUSU_NOTARY_PROFILE="pusu-notary"   # xcrun notarytool store-credentials ile kaydedilen profil
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build.sh release

APP="build/Pusu.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DIST="dist"
ZIP="$DIST/Pusu-$VERSION.zip"
DMG="$DIST/Pusu-$VERSION.dmg"

rm -rf "$DIST"
mkdir -p "$DIST"

# Universal ve minimum macOS kontrolü: yanlış mimariyle yayın yapılmasın.
for BINARY in "$APP/Contents/MacOS/Pusu" "$APP/Contents/Resources/pusu-helper"; do
    ARCHS="$(lipo -archs "$BINARY")"
    [[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || { echo "Universal değil: $BINARY ($ARCHS)" >&2; exit 1; }
done

notarize() {
    local file="$1"
    [ -n "${PUSU_NOTARY_PROFILE:-}" ] || return 0
    xcrun notarytool submit "$file" --keychain-profile "$PUSU_NOTARY_PROFILE" --wait
}

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
if [ -n "${PUSU_NOTARY_PROFILE:-}" ]; then
    notarize "$ZIP"
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi

STAGING="$(mktemp -d -t pusu-dmg)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/Pusu.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Pusu $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
if [ -n "${PUSU_SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$PUSU_SIGN_IDENTITY" --timestamp "$DMG"
fi
if [ -n "${PUSU_NOTARY_PROFILE:-}" ]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
fi

(cd "$DIST" && shasum -a 256 "Pusu-$VERSION.zip" "Pusu-$VERSION.dmg" > SHA256SUMS)

# Sparkle appcast'i (uygulama içi güncelleme): sürümle birlikte yüklenir.
scripts/appcast.sh

echo ""
echo "Sürüm $VERSION hazır:"
cat "$DIST/SHA256SUMS"
