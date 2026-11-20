#!/bin/bash
# Kaynaktan derleyip /Applications/Pusu.app olarak kurar ve `pusu` komutunu bağlar.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build.sh release

# Çalışan Pusu'yu düzgünce kapat: böylece açık oturum geçmişe yazılır ve kapak modu geri alınır.
if pgrep -x Pusu >/dev/null 2>&1; then
    osascript -e 'tell application id "local.kan.pusu" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
        pgrep -x Pusu >/dev/null 2>&1 || break
        sleep 0.2
    done
    pkill -x Pusu 2>/dev/null || true
fi

rm -rf /Applications/Pusu.app
cp -R build/Pusu.app /Applications/Pusu.app
xattr -dr com.apple.quarantine /Applications/Pusu.app 2>/dev/null || true

# Terminalden `pusu ...` kullanımı için sembolik bağ.
CLI_TARGET="/Applications/Pusu.app/Contents/MacOS/Pusu"
CLI_LINKED=0
for DIR in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
    if [ -d "$DIR" ] && [ -w "$DIR" ]; then
        ln -sf "$CLI_TARGET" "$DIR/pusu"
        echo "CLI: $DIR/pusu"
        CLI_LINKED=1
        break
    fi
done
if [ "$CLI_LINKED" -eq 0 ]; then
    echo "Not: yazılabilir bir PATH dizini bulunamadı. CLI için:"
    echo "  sudo ln -sf \"$CLI_TARGET\" /usr/local/bin/pusu"
fi

open -a /Applications/Pusu.app
echo "Kuruldu: /Applications/Pusu.app"
