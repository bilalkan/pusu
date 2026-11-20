#!/bin/bash
# Pusu'yu, yardımcısını, giriş öğesini ve verilerini kaldırır.
# Yardımcı kuruluysa SleepDisabled'ı eski değerine döndürmek için yönetici parolası ister.
set -euo pipefail

if pgrep -x Pusu >/dev/null 2>&1; then
    osascript -e 'tell application id "local.kan.pusu" to quit' >/dev/null 2>&1 || true
    sleep 1
    pkill -x Pusu 2>/dev/null || true
fi

LABEL=local.kan.pusu.helper
if [ -f "/Library/LaunchDaemons/$LABEL.plist" ] || [ -f "/Library/PrivilegedHelperTools/$LABEL" ]; then
    ROOT_SCRIPT="$(mktemp -t pusu-uninstall)"
    trap 'rm -f "$ROOT_SCRIPT"' EXIT
    cat > "$ROOT_SCRIPT" <<ROOT
/bin/launchctl bootout system/$LABEL >/dev/null 2>&1 || true
if [ -f /var/db/$LABEL.state ]; then
    ORIGINAL=\$(/bin/cat /var/db/$LABEL.state)
    case "\$ORIGINAL" in 0|1) /usr/bin/pmset -a disablesleep "\$ORIGINAL" || true ;; esac
fi
/bin/rm -f /var/db/$LABEL.state /Library/LaunchDaemons/$LABEL.plist /Library/PrivilegedHelperTools/$LABEL /var/run/$LABEL.sock /var/log/$LABEL.log
ROOT
    osascript -e "do shell script \"/bin/sh '$ROOT_SCRIPT'\" with administrator privileges" >/dev/null \
        || echo "Uyarı: yardımcı kaldırılamadı (yönetici izni verilmedi)."
fi

launchctl bootout "gui/$(id -u)/local.kan.pusu.login" >/dev/null 2>&1 || true
rm -f "$HOME/Library/LaunchAgents/local.kan.pusu.login.plist"
rm -rf "$HOME/Library/Application Support/Pusu"
defaults delete local.kan.pusu >/dev/null 2>&1 || true

for LINK in /opt/homebrew/bin/pusu /usr/local/bin/pusu "$HOME/.local/bin/pusu"; do
    if [ -L "$LINK" ] && [[ "$(readlink "$LINK")" == *Pusu.app* ]]; then
        rm -f "$LINK"
    fi
done

rm -rf /Applications/Pusu.app
echo "Pusu kaldırıldı."
