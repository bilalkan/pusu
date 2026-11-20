#!/bin/bash
# dist/ içindeki sürümden Homebrew cask dosyasını üretir (bilalkan/homebrew-tap için).
#
#   scripts/package.sh && scripts/cask.sh > ../homebrew-tap/Casks/pusu.rb
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ZIP="dist/Pusu-$VERSION.zip"
[ -f "$ZIP" ] || { echo "$ZIP yok; önce scripts/package.sh çalıştırın." >&2; exit 1; }
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

# Şablon tırnaklı heredoc'tadır: içindeki $ ve ` karakterleri kabukta asla
# yorumlanmaz. Yalnızca __VERSION__ ve __SHA256__ yer tutucuları doldurulur.
IFS= read -r -d '' TEMPLATE <<'CASK' || true
cask "pusu" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/bilalkan/pusu/releases/download/v#{version}/Pusu-#{version}.zip"
  name "Pusu"
  desc "Menu bar app that keeps the system awake"
  homepage "https://github.com/bilalkan/pusu"

  depends_on macos: :ventura

  app "Pusu.app"
  binary "#{appdir}/Pusu.app/Contents/MacOS/Pusu", target: "pusu"

  # Pusu henüz Apple tarafından notarize edilmiyor; Applications'a taşınmadan önce
  # karantina işareti kaldırılır ki ilk açılışta Gatekeeper engellemesin.
  preflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "Pusu.app"], chdir: "."
  end

  # Normal kaldırma ve güncelleme yalnızca uygulamayı kapatır; böylece brew upgrade
  # yönetici yardımcısını silmez ve parola sormaz. Yardımcı, uygulama 15 dakika boyunca
  # ortada olmazsa SleepDisabled'ı geri yükleyip kendini kaldırır. --zap hemen kaldırır
  # (launchctl bootout yardımcıya SIGTERM gönderir, o da SleepDisabled'ı geri yükler).
  uninstall quit: "local.kan.pusu"

  # Yardımcı çalışmıyor olsa da kayıtlı eski değer (yalnızca 0/1) silinmeden önce geri yüklenir.
  zap launchctl: "local.kan.pusu.helper",
      script:    {
        executable:   "/bin/sh",
        args:         [
          "-c",
          "S=/var/db/local.kan.pusu.helper.state; [ -f $S ] || exit 0; V=$(/bin/cat $S); " \
          "case $V in 0|1) /usr/bin/pmset -a disablesleep $V;; esac",
        ],
        sudo:         true,
        must_succeed: false,
      },
      delete:    [
        "/Library/LaunchDaemons/local.kan.pusu.helper.plist",
        "/Library/PrivilegedHelperTools/local.kan.pusu.helper",
        "/var/db/local.kan.pusu.helper.state",
        "/var/log/local.kan.pusu.helper.log",
        "/var/run/local.kan.pusu.helper.sock",
      ],
      trash:     [
        "~/Library/Application Support/Pusu",
        "~/Library/LaunchAgents/local.kan.pusu.login.plist",
        "~/Library/Preferences/local.kan.pusu.plist",
      ]

  caveats <<~EOS
    Pusu is not notarized by Apple. The cask removes the quarantine flag so it opens normally.
    Lid mode needs administrator rights; install the optional helper from Settings › System.
    Upgrades keep the helper. After `brew uninstall`, the helper restores SleepDisabled and
    removes itself about 15 minutes later; `brew uninstall --zap` removes it right away.
    If you use lid mode without the helper, turn it off in Pusu before uninstalling;
    otherwise run `sudo pmset -a disablesleep 0` afterwards.
  EOS
end
CASK

TEMPLATE="${TEMPLATE//__VERSION__/$VERSION}"
TEMPLATE="${TEMPLATE//__SHA256__/$SHA}"
printf '%s' "$TEMPLATE"
