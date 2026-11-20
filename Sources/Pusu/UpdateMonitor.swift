import AppKit
import Combine
import PusuCore

/// İsteğe bağlı güncelleme kontrolünü zamanlar ve sonucu menüye, bildirime ve Ayarlar'a yayar.
final class UpdateMonitor: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case failed
    }

    @Published private(set) var state: State = .idle

    var available: AvailableUpdate? {
        if case .available(let update) = state { return update }
        return nil
    }

    private let settings: SettingsStore
    private let currentVersion: String
    private let notify: (String, String) -> Void
    private var timer: Timer?

    init(settings: SettingsStore, currentVersion: String, notify: @escaping (String, String) -> Void) {
        self.settings = settings
        self.currentVersion = currentVersion
        self.notify = notify
    }

    /// Açılışta ve saatte bir: izin varsa ve son kontrolden bu yana bir gün geçtiyse kontrol eder.
    func start() {
        checkIfDue()
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            self?.checkIfDue()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func checkIfDue() {
        guard UpdateChecker.isDue(enabled: settings.updateCheckEnabled, lastCheck: settings.lastUpdateCheck) else { return }
        check(userInitiated: false)
    }

    /// - Parameter userInitiated: "Şimdi kontrol et" düğmesi; izin ayarından bağımsız çalışır.
    func check(userInitiated: Bool) {
        guard state != .checking else { return }
        state = .checking
        UpdateChecker.fetchLatest { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let latest):
                    self.settings.lastUpdateCheck = Date()
                    if let update = UpdateChecker.newer(latest, than: self.currentVersion) {
                        self.state = .available(update)
                        if !userInitiated { self.notifyOnce(update) }
                    } else {
                        self.state = latest == nil ? .failed : .upToDate
                    }
                case .failure:
                    self.state = .failed
                }
                if userInitiated { self.presentManualResult() }
            }
        }
    }

    /// "Güncellemeleri denetle…" sonucunu doğrudan gösterir.
    private func presentManualResult() {
        switch state {
        case .available:
            settings.notifiedUpdateVersion = available?.version
            presentUpdate()
        case .upToDate:
            AppActivation.activate()
            let alert = NSAlert()
            alert.messageText = L("Pusu güncel", "Pusu is up to date")
            alert.informativeText = L("Kullandığınız \(currentVersion) en son sürüm.", "You're running \(currentVersion), the latest version.")
            alert.addButton(withTitle: L("Tamam", "OK"))
            alert.runModal()
        case .failed:
            AppActivation.activate()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("Güncellemeler denetlenemedi", "Couldn't check for updates")
            alert.informativeText = L(
                "GitHub'a ulaşılamadı. İnternet bağlantınızı kontrol edip yeniden deneyin ya da sürümler sayfasına bakın.",
                "GitHub couldn't be reached. Check your internet connection and try again, or open the releases page."
            )
            alert.addButton(withTitle: L("Tamam", "OK"))
            alert.addButton(withTitle: L("Sürümler Sayfası", "Releases Page"))
            if alert.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.open(UpdateChecker.releasesPage)
            }
        case .idle, .checking:
            break
        }
    }

    private func notifyOnce(_ update: AvailableUpdate) {
        guard settings.notifiedUpdateVersion != update.version else { return }
        settings.notifiedUpdateVersion = update.version
        notify(
            L("Pusu \(update.version) yayında", "Pusu \(update.version) is available"),
            UpdateChecker.installedWithHomebrew()
                ? L("Güncellemek için: brew upgrade --cask pusu", "To update: brew upgrade --cask pusu")
                : L("Menüden ayrıntılara bakabilirsiniz.", "See the details from the Pusu menu.")
        )
    }

    /// Menüdeki "Yeni sürüm" öğesi: Homebrew kurulumunda komutu gösterir, değilse sürüm sayfasını açar.
    func presentUpdate() {
        guard let update = available else { return }
        guard UpdateChecker.installedWithHomebrew() else {
            AppActivation.activate()
            let alert = NSAlert()
            alert.messageText = L("Pusu \(update.version) yayında", "Pusu \(update.version) is available")
            alert.informativeText = L(
                "Şu an \(currentVersion) kullanıyorsunuz. Yeni sürümü sürümler sayfasından indirip Uygulamalar klasörüne sürükleyin.",
                "You're running \(currentVersion). Download the new version from the releases page and drag it to Applications."
            )
            alert.addButton(withTitle: L("İndirme Sayfası", "Download Page"))
            alert.addButton(withTitle: L("Daha Sonra", "Later"))
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(update.releaseURL)
            }
            return
        }
        AppActivation.activate()
        let alert = NSAlert()
        alert.messageText = L("Pusu \(update.version) yayında", "Pusu \(update.version) is available")
        alert.informativeText = L(
            "Pusu Homebrew ile kurulu. Güncellemek için Terminal'de şunu çalıştırın:\n\n\(UpdateChecker.homebrewUpgradeCommand)",
            "Pusu was installed with Homebrew. To update, run this in Terminal:\n\n\(UpdateChecker.homebrewUpgradeCommand)"
        )
        alert.addButton(withTitle: L("Komutu Kopyala", "Copy Command"))
        alert.addButton(withTitle: L("Sürüm Notları", "Release Notes"))
        alert.addButton(withTitle: L("Kapat", "Close"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(UpdateChecker.homebrewUpgradeCommand, forType: .string)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(update.releaseURL)
        default:
            break
        }
    }

    /// Kullanıcıya bir kez sorulur (yeni kurulumda karşılamadan sonra, güncellemede ilk açılışta).
    func askForPermissionIfNeeded() {
        guard !settings.updateCheckAsked else { return }
        AppActivation.activate()
        let alert = NSAlert()
        alert.messageText = L("Güncellemeler nasıl denetlensin?", "How should Pusu check for updates?")
        alert.informativeText = L(
            "Otomatik seçerseniz Pusu günde bir kez GitHub'dan en son sürüm numarasını okur ve yeni sürüm çıkınca haber verir. Bunun dışında hiçbir bağlantı kurmaz; kimlik ya da kullanım verisi gönderilmez.\n\nHer iki durumda da menüdeki \"Güncellemeleri Denetle…\" ile istediğiniz an elle bakabilirsiniz. Ayarlar'dan sonra değiştirebilirsiniz.",
            "If you choose automatic, Pusu reads the latest version number from GitHub once a day and tells you when a new version is out. It makes no other connection and sends no identifying or usage data.\n\nEither way, you can check anytime with \"Check for Updates…\" in the menu. You can change this later in Settings."
        )
        alert.addButton(withTitle: L("Günde Bir Kez Otomatik", "Automatically, Once a Day"))
        alert.addButton(withTitle: L("Yalnızca Ben İstediğimde", "Only When I Ask"))
        settings.updateCheckEnabled = alert.runModal() == .alertFirstButtonReturn
        if settings.updateCheckEnabled { checkIfDue() }
    }
}
