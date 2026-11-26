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
#                               Verilirse hardened runtime ile imzalar.
#   PUSU_SELF_SIGN_NAME         Kalıcı (kendinden imzalı) sertifikanın adı; varsayılan
#                               "Pusu Code Signing". Anahtar zincirinde varsa onunla, yoksa ad-hoc
#                               imzalanır. Sabit imza sayesinde macOS verilen izinleri (ör. olay
#                               gönderme) güncellemelerde hatırlar; ad-hoc imza her derlemede değişir.
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

# Sparkle (uygulama içi güncelleme). Pusu sandbox'lı değil: XPC servislerine gerek yok
# (Sparkle belgeleri), çıkarılır. Kalan Autoupdate ve Updater.app aşağıda imzalanır.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"

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
SELF_SIGN_NAME="${PUSU_SELF_SIGN_NAME:-Pusu Code Signing}"
# Güvenilir işaretlenmemiş sertifika da imzalayabilir; SHA-1 ile seçilir (-v kullanılmaz).
SELF_SIGN_HASH="$(security find-identity -p codesigning 2>/dev/null \
    | awk -v name="\"$SELF_SIGN_NAME\"" 'index($0, name) {print $2; exit}')"
if [ -n "${PUSU_SIGN_IDENTITY:-}" ]; then
    SIGN_ARGS=(--force --options runtime --timestamp --sign "$PUSU_SIGN_IDENTITY")
    SIGNED_WITH="$PUSU_SIGN_IDENTITY"
elif [ -n "$SELF_SIGN_HASH" ]; then
    # Hardened runtime yok: kitaplık doğrulaması ekip kimliği ister, kendinden imzalı
    # sertifikada ekip kimliği olmadığı için Sparkle.framework yüklenemezdi.
    SIGN_ARGS=(--force --timestamp=none --sign "$SELF_SIGN_HASH")
    SIGNED_WITH="$SELF_SIGN_NAME"
else
    SIGN_ARGS=(--force --sign - --timestamp=none)
    SIGNED_WITH="ad-hoc"
fi
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_ARGS[@]}" "$SPARKLE/Versions/B/Autoupdate"
codesign "${SIGN_ARGS[@]}" "$SPARKLE/Versions/B/Updater.app"
codesign "${SIGN_ARGS[@]}" "$SPARKLE"
codesign "${SIGN_ARGS[@]}" --identifier local.kan.pusu.helper "$APP/Contents/Resources/pusu-helper"
# İmzalı yardımcının özeti Info.plist'e yazılır; kurulumda root bu özeti doğrular.
HELPER_SHA="$(shasum -a 256 "$APP/Contents/Resources/pusu-helper" | awk '{print $1}')"
plutil -replace PusuHelperSHA256 -string "$HELPER_SHA" "$APP/Contents/Info.plist"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --deep "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Pusu")"
echo "$APP · v$VERSION · $ARCHS · ikon $CONCEPT · imza: $SIGNED_WITH"
