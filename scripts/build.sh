#!/bin/bash
# Pusu.app paketini üretir.
#
#   scripts/build.sh            # release, universal (arm64 + x86_64)
#   scripts/build.sh debug      # debug, yalnızca bu Mac'in mimarisi
#
# Ortam değişkenleri:
#   PUSU_ICON_CONCEPT=A|B       Uygulama ikonu (varsayılan A)
#   PUSU_UNIVERSAL=0            Release'i yalnızca yerel mimari için derle
#   PUSU_SIGN_IDENTITY="Developer ID Application: …"
#                               Verilirse hardened runtime ile imzalar; yoksa ad-hoc imza.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
CONCEPT="${PUSU_ICON_CONCEPT:-A}"
CONCEPT="$(echo "$CONCEPT" | tr '[:lower:]' '[:upper:]')"

case "$CONFIG" in
    release|debug) ;;
    *) echo "Kullanım: scripts/build.sh [release|debug]" >&2; exit 2 ;;
esac

case "$CONCEPT" in
    A|B) ;;
    *) echo "PUSU_ICON_CONCEPT A veya B olmalı (verilen: $CONCEPT)" >&2; exit 2 ;;
esac

if [ ! -f "Resources/Icons/$CONCEPT/Pusu.icns" ]; then
    scripts/make-icons.sh
fi

ARCH_FLAGS=()
if [ "$CONFIG" = "release" ] && [ "${PUSU_UNIVERSAL:-1}" = "1" ]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product Pusu
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product pusu-helper
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="build/Pusu.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Pusu" "$APP/Contents/MacOS/Pusu"
cp "$BIN/pusu-helper" "$APP/Contents/Resources/pusu-helper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "Resources/Icons/$CONCEPT/Pusu.icns" "$APP/Contents/Resources/Pusu.icns"
cp "Resources/Icons/$CONCEPT/pusu-icon-1024.png" "$APP/Contents/Resources/pusu-icon-1024.png"
plutil -replace PusuIconConcept -string "$CONCEPT" "$APP/Contents/Info.plist"

# Metinler kodda iki dilli; bu klasörler macOS'un uygulamayı Türkçe/İngilizce
# olarak tanıması (dil seçimi, sistem diyalogları) için gereklidir.
for LANG_CODE in en tr; do
    mkdir -p "$APP/Contents/Resources/$LANG_CODE.lproj"
    printf '"CFBundleDisplayName" = "Pusu";\n"CFBundleName" = "Pusu";\n' \
        > "$APP/Contents/Resources/$LANG_CODE.lproj/InfoPlist.strings"
done

printf 'APPL????' > "$APP/Contents/PkgInfo"
chmod +x "$APP/Contents/MacOS/Pusu" "$APP/Contents/Resources/pusu-helper"

plutil -lint "$APP/Contents/Info.plist" >/dev/null

# İç içe kodu önce, paketi en son imzala (--deep kullanılmaz).
if [ -n "${PUSU_SIGN_IDENTITY:-}" ]; then
    SIGN_ARGS=(--force --options runtime --timestamp --sign "$PUSU_SIGN_IDENTITY")
else
    SIGN_ARGS=(--force --sign - --timestamp=none)
fi
codesign "${SIGN_ARGS[@]}" --identifier local.kan.pusu.helper "$APP/Contents/Resources/pusu-helper"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --deep "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Pusu")"
echo "$APP · v$VERSION · $ARCHS · ikon $CONCEPT"
