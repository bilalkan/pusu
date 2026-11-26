#!/bin/bash
# dist/ içindeki zip için Sparkle appcast'i üretir: dist/appcast.xml.
# Sürümle birlikte GitHub'a yüklenir; uygulama onu
# https://github.com/bilalkan/pusu/releases/latest/download/appcast.xml adresinden okur.
#
#   scripts/appcast.sh            (package.sh sonunda kendiliğinden çalışır)
#
# İmza anahtarı: PUSU_SPARKLE_KEY_FILE (varsayılan ~/.config/pusu/sparkle-private-key);
# dosya yoksa giriş anahtar zincirindeki "pusu" hesabı kullanılır.
# Sürüm notları docs/CHANGELOG.md'deki "## <sürüm>" bölümünden alınır.
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST=Resources/Info.plist
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
ZIP="dist/Pusu-$VERSION.zip"
[ -f "$ZIP" ] || { echo "$ZIP yok; önce scripts/package.sh çalıştırın." >&2; exit 1; }

SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
[ -x "$SIGN_UPDATE" ] || swift package resolve >/dev/null
KEY_FILE="${PUSU_SPARKLE_KEY_FILE:-$HOME/.config/pusu/sparkle-private-key}"
if [ -f "$KEY_FILE" ]; then
    SIGNATURE="$("$SIGN_UPDATE" --ed-key-file "$KEY_FILE" "$ZIP")"
else
    SIGNATURE="$("$SIGN_UPDATE" --account pusu "$ZIP")"
fi
# Çıktı: sparkle:edSignature="…" length="…"
[[ "$SIGNATURE" == sparkle:edSignature=* ]] || { echo "İmza üretilemedi: $SIGNATURE" >&2; exit 1; }

# Gizli anahtar, uygulamaya gömülü açık anahtarla (SUPublicEDKey) eşleşmeli; yoksa
# kullanıcılardaki Pusu güncellemeyi reddeder. Anahtar dosyası varsa bu kontrol edilir.
if [ -f "$KEY_FILE" ]; then
    PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")"
    DERIVED="$(swift scripts/ed-public-key.swift "$KEY_FILE")"
    [ "$DERIVED" = "$PUBLIC_KEY" ] || { echo "Anahtar Info.plist'teki SUPublicEDKey ile eşleşmiyor" >&2; exit 1; }
    ED_SIG="$(sed -E 's/.*edSignature="([^"]+)".*/\1/' <<<"$SIGNATURE")"
    "$SIGN_UPDATE" --verify --ed-key-file "$KEY_FILE" "$ZIP" "$ED_SIG" >/dev/null
fi

python3 - "$VERSION" "$BUILD" "$MIN_OS" "$SIGNATURE" > dist/appcast.xml <<'PY'
import html, re, sys
from email.utils import formatdate

version, build, min_os, signature = sys.argv[1:5]

text = open("docs/CHANGELOG.md", encoding="utf-8").read()
match = re.search(r"^## " + re.escape(version) + r"\b.*?\n(.*?)(?=^## |\Z)", text, re.S | re.M)
if not match:
    sys.exit(f"docs/CHANGELOG.md içinde '## {version}' bölümü yok")

def inline(s):
    s = html.escape(s, quote=False)
    s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
    s = re.sub(r"`(.+?)`", r"<code>\1</code>", s)
    s = re.sub(r"\[(.+?)\]\((https://[^)\s]+)\)", r'<a href="\2">\1</a>', s)
    return s

parts, items = [], []
for line in match.group(1).strip().splitlines():
    if line.startswith("- "):
        items.append(f"<li>{inline(line[2:])}</li>")
        continue
    if items:
        parts.append("<ul>" + "".join(items) + "</ul>")
        items = []
    if line.strip():
        parts.append(f"<p>{inline(line.strip())}</p>")
if items:
    parts.append("<ul>" + "".join(items) + "</ul>")
notes = "".join(parts).replace("]]>", "]]&gt;")

url = f"https://github.com/bilalkan/pusu/releases/download/v{version}/Pusu-{version}.zip"
print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Pusu</title>
    <link>https://github.com/bilalkan/pusu</link>
    <item>
      <title>Pusu {version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{min_os}</sparkle:minimumSystemVersion>
      <link>https://github.com/bilalkan/pusu/releases/tag/v{version}</link>
      <description><![CDATA[{notes}]]></description>
      <enclosure url="{url}" type="application/octet-stream" {signature} />
    </item>
  </channel>
</rss>""")
PY
xmllint --noout dist/appcast.xml
echo "dist/appcast.xml hazır (Pusu $VERSION, build $BUILD)"
