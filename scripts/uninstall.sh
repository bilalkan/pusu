#!/bin/bash
# Pusu'yu, yardımcısını, giriş öğesini ve verilerini kaldırır.
# Gerekirse SleepDisabled'ı Pusu'dan önceki değerine döndürmek için yönetici parolası ister.
set -euo pipefail

LABEL=local.kan.pusu.helper
STATE="/var/db/$LABEL.state"

if pgrep -x Pusu >/dev/null 2>&1; then
    osascript -e 'tell application id "local.kan.pusu" to quit' >/dev/null 2>&1 || true
    sleep 1
    pkill -x Pusu 2>/dev/null || true
fi

# Yardımcısız kapak modu: Pusu'dan önceki değer kullanıcının ayarlarında saklanır.
# Ayarlar silinmeden önce okunur ve yardımcı kaydına göre önceliklidir.
RESTORE=""
if [ "$(defaults read local.kan.pusu pusu.fallbackSleepDisabledActive 2>/dev/null || echo 0)" = "1" ]; then
    case "$(defaults read local.kan.pusu pusu.fallbackSleepDisabledOriginal 2>/dev/null || echo 0)" in
        1) RESTORE=1 ;;
        *) RESTORE=0 ;;
    esac
fi

NEEDS_ROOT=0
if [ -n "$RESTORE" ] || [ -e "$STATE" ] || [ -e "/Library/LaunchDaemons/$LABEL.plist" ] || [ -e "/Library/PrivilegedHelperTools/$LABEL" ]; then
    NEEDS_ROOT=1
fi

if [ "$NEEDS_ROOT" = "1" ]; then
    # Betik diske yazılmaz; osascript'e argüman olarak verilir (değiştirilemez).
    ROOT_SCRIPT="set -u
/bin/launchctl bootout system/$LABEL >/dev/null 2>&1 || true
RESTORE='$RESTORE'
if [ -z \"\$RESTORE\" ] && [ -f $STATE ]; then
    RESTORE=\$(/bin/cat $STATE)
fi
case \"\$RESTORE\" in 0|1) /usr/bin/pmset -a disablesleep \"\$RESTORE\" ;; esac
/bin/rm -f $STATE /Library/LaunchDaemons/$LABEL.plist /Library/PrivilegedHelperTools/$LABEL /var/run/$LABEL.sock /var/log/$LABEL.log"
    if ! osascript \
        -e 'on run argv' \
        -e 'do shell script (item 1 of argv) with administrator privileges' \
        -e 'end run' \
        "$ROOT_SCRIPT" >/dev/null; then
        echo "Uyarı: yönetici izni verilmedi; yardımcı kaldırılmadı ve SleepDisabled değişmedi."
        echo "Gerekirse elle: sudo pmset -a disablesleep 0"
        exit 1
    fi
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
