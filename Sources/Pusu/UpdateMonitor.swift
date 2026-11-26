import AppKit
import Combine
import PusuCore
import Sparkle

/// Sparkle köprüsü. Zamanlanmış denetimi Sparkle yapmaz (Info.plist: `SUEnableAutomaticChecks`
/// false); ne zaman bakılacağına `UpdateMonitor` karar verir. Sparkle yalnızca yeni sürüm
/// bulunduğunda devreye girer: sürüm notlarını gösterir, paketi indirir, EdDSA imzasını
/// `SUPublicEDKey` ile doğrular, Pusu'yu kapatıp yenisini kurar ve yeniden açar.
final class SparkleBridge: NSObject, SPUUpdaterDelegate {
    /// Yalnızca yerel deneme için: `defaults write local.kan.pusu pusu.updateFeedURL http://127.0.0.1:…`.
    /// İmza doğrulaması değişmez; başka bir adresten gelen paket de aynı anahtarla imzalı olmalı.
    static let feedOverrideKey = "pusu.updateFeedURL"

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    /// Sparkle Pusu'yu kapatıp yeni sürümü açmadan hemen önce çağrılır.
    var onWillRelaunch: (() -> Void)?

    func start() { _ = controller }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        onWillRelaunch?()
    }

    /// Sparkle'ın güncelleme penceresini açar (yeni sürüm yoksa "güncel" der).
    func showUpdate() {
        AppActivation.activate()
        controller.checkForUpdates(nil)
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: Self.feedOverrideKey)
    }
}

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
    let sparkle = SparkleBridge()

    init(settings: SettingsStore, currentVersion: String, notify: @escaping (String, String) -> Void) {
        self.settings = settings
        self.currentVersion = currentVersion
        self.notify = notify
    }

    /// Açılışta ve saatte bir: izin varsa ve son kontrolden bu yana bir gün geçtiyse kontrol eder.
    func start() {
        sparkle.start()
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
            L("Menüden tek tıkla güncelleyebilirsiniz.", "Update with one click from the Pusu menu.")
        )
    }

    /// Menüdeki "Yeni sürüm" öğesi: Sparkle sürüm notlarını gösterir, onaylanınca indirip kurar.
    /// Homebrew kurulumunda da aynı yol kullanılır (cask `auto_updates true`).
    func presentUpdate() {
        sparkle.showUpdate()
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
