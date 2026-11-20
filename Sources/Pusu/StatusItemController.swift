import AppKit
import Combine
import PusuCore

struct StatusActions {
    var toggle: () -> Void
    var start: (PusuDuration) -> Void
    var stop: () -> Void
    var customDuration: () -> Void
    var setLid: (Bool) -> Void
    var installHelper: () -> Void
    var removeHelper: () -> Void
    var remoteMode: () -> Void
    var blackout: () -> Void
    var lock: () -> Void
    var wake: () -> Void
    var openSharingSettings: () -> Void
    var openSettings: () -> Void
    var copyDiagnostics: () -> Void
    var about: () -> Void
    var checkForUpdates: () -> Void
    var showUpdate: () -> Void
    var quit: () -> Void
}

final class StatusItemController: NSObject, NSMenuDelegate {
    private struct MenuCache {
        var helper: HelperStatus?
        var sleepDisabled: Bool?
        var sharingState: ScreenSharingState = .unknown
        var remoteManagement = false
        var loaded = false
    }

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let session: SessionController
    private let settings: SettingsStore
    private let actions: StatusActions
    private let iconView: PusuStatusIconProtocol
    private var cacheTimer: Timer?
    private var cache = MenuCache()
    private var cacheRefreshing = false
    private var cacheRefreshPending = false
    private var cancellables = Set<AnyCancellable>()

    private let updates: UpdateMonitor

    init(session: SessionController, settings: SettingsStore, updates: UpdateMonitor, actions: StatusActions) {
        self.session = session
        self.settings = settings
        self.updates = updates
        self.actions = actions
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        guard let button = statusItem.button else {
            fatalError("Pusu status item button unavailable")
        }

        if IconConcept.active == .keyhole {
            self.iconView = PusuStatusIcon(button: button)
        } else {
            self.iconView = PusuStatusIconKapi(button: button)
        }

        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        // Menü kalıcı olarak bağlanmaz: sol tık aç/kapat, sağ tık (veya Control-tık) menü.
        button.target = self
        button.action = #selector(statusButtonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        button.setAccessibilityLabel("Pusu")
        button.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: L("Menüyü göster", "Show menu"), target: self, selector: #selector(showMenuAccessibilityAction)),
        ])

        session.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
            .store(in: &cancellables)
        session.clock.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
            .store(in: &cancellables)
        settings.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
            .store(in: &cancellables)

        refreshMenuCache()
        let cacheTimer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshMenuCache()
        }
        RunLoop.main.add(cacheTimer, forMode: .common)
        self.cacheTimer = cacheTimer

        updateStatusItem()
    }

    deinit {
        cacheTimer?.invalidate()
        cancellables.removeAll()
    }

    // MARK: - Status item

    private var iconState: PusuIconState {
        // Önce Pusu'nun kendi durumu. Dışarıdan gelen SleepDisabled, Pusu kapalıyken
        // ikonu "açık" göstermemeli; o ayrı bir uyarı satırı.
        guard session.isOn else { return .off }
        if session.remoteBlankActive { return .vncLock }
        if session.lidMode || session.sleepDisabledActive { return .lidClosed }
        if let seconds = session.duration?.seconds,
           let remaining = session.remaining,
           seconds > 0 {
            return .timed(remaining: max(0, min(1, remaining / seconds)))
        }
        return .awake
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        iconView.update(iconState)

        let title: String
        if session.isOn, settings.showCountdown, let remaining = session.remaining {
            title = " " + TimeText.countdown(remaining)
        } else {
            title = ""
        }
        if button.title != title {
            button.title = title
        }
        iconView.layoutOverlay()

        var tooltip = session.isOn ? L("Pusu açık", "Pusu is on") : L("Pusu kapalı", "Pusu is off")
        if let remaining = session.remaining, session.isOn {
            tooltip += " · \(TimeText.countdown(remaining))"
        }
        if session.lidMode || session.sleepDisabledActive { tooltip += L(" · kapak modu", " · lid mode") }
        if session.remoteBlankActive { tooltip += L(" · ekran kapalı", " · display off") }
        if let battery = session.battery, battery.isPresent {
            tooltip += " · \(battery.powerLabel)"
        }
        if settings.clickTogglesSession {
            tooltip += "\n" + L("Tıkla: aç/kapat · Sağ tık: menü", "Click: on/off · Right-click: menu")
        }
        if button.toolTip != tooltip {
            button.toolTip = tooltip
        }
    }

    // MARK: - Background status cache

    private func refreshMenuCache() {
        guard !cacheRefreshing else {
            cacheRefreshPending = true
            return
        }
        cacheRefreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let settings = self?.settings else { return }
            let helper = HelperClient.ping(timeout: 0.6)
            let sleepDisabled = LidController(settings: settings).sleepDisabled(timeout: 2)
            let remote = RemoteController()
            let sharing = remote.screenSharingState(timeout: 2)
            let remoteManagement = remote.remoteManagementRunning(timeout: 2)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cache = MenuCache(
                    helper: helper,
                    sleepDisabled: sleepDisabled,
                    sharingState: sharing,
                    remoteManagement: remoteManagement,
                    loaded: true
                )
                self.cacheRefreshing = false
                self.updateStatusItem()
                if self.cacheRefreshPending {
                    self.cacheRefreshPending = false
                    self.refreshMenuCache()
                }
            }
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        refreshMenuCache()
        addHeader(to: menu)

        if let update = updates.available {
            menu.addItem(item(
                L("Yeni sürüm: Pusu \(update.version)…", "New version: Pusu \(update.version)…"),
                action: #selector(showUpdate),
                image: "arrow.down.circle"
            ))
            menu.addItem(.separator())
        }

        if session.isOn, let remaining = session.remaining {
            let timerItem = disabledItem(L("Kalan: \(TimeText.countdown(remaining))", "Remaining: \(TimeText.countdown(remaining))"))
            timerItem.image = symbol("timer")
            menu.addItem(timerItem)
        }

        if session.isOn {
            menu.addItem(item(L("15 dakika uzat", "Extend by 15 minutes"), action: #selector(extendSession), image: "plus.circle"))
        }

        let shortcut = HotKeyDisplay.menuEquivalent(for: settings.hotkeyPreset)
        let toggleItem = item(
            session.isOn ? L("Kapat", "Turn Off") : L("Başlat", "Turn On"),
            action: #selector(toggleActive),
            key: shortcut?.key ?? "",
            keyModifiers: shortcut?.modifiers ?? [],
            image: session.isOn ? "power" : "power.circle.fill"
        )
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let durationItem = item(L("Şu kadar başlat", "Turn On For"), action: nil, image: "clock")
        durationItem.submenu = makeDurationMenu()
        menu.addItem(durationItem)

        let lidItem = item(L("Kapak modu", "Lid Mode"), action: nil, image: "laptopcomputer")
        lidItem.submenu = makeLidMenu()
        menu.addItem(lidItem)

        let remoteItem = item(L("Uzak erişim (VNC)", "Remote Access (VNC)"), action: nil, image: "display")
        remoteItem.submenu = makeRemoteMenu()
        menu.addItem(remoteItem)

        let optionsItem = item(L("Seçenekler", "Options"), action: nil, image: "gearshape")
        optionsItem.submenu = makeOptionsMenu()
        menu.addItem(optionsItem)

        menu.addItem(.separator())

        let settingsItem = item(L("Ayarlar…", "Settings…"), action: #selector(openSettings), key: ",", image: "slider.horizontal.3")
        menu.addItem(settingsItem)
        menu.addItem(item(L("Güncellemeleri Denetle…", "Check for Updates…"), action: #selector(checkForUpdates), image: "arrow.triangle.2.circlepath"))
        menu.addItem(item(L("Pusu Hakkında", "About Pusu"), action: #selector(about), image: "info.circle"))
        menu.addItem(item(L("Pusu'dan Çık", "Quit Pusu"), action: #selector(quit), key: "q", image: "rectangle.portrait.and.arrow.right"))
    }

    private func makeSubmenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        return menu
    }

    private func makeDurationMenu() -> NSMenu {
        let menu = makeSubmenu()
        for (index, preset) in PusuDuration.presets.enumerated() {
            let presetItem = item(
                preset.label,
                action: #selector(startPreset(_:)),
                state: session.isOn && session.duration == preset ? .on : .off
            )
            presetItem.tag = index
            menu.addItem(presetItem)
        }
        menu.addItem(.separator())
        menu.addItem(item(L("Özel süre…", "Custom Duration…"), action: #selector(customDuration), image: "slider.horizontal.3"))
        return menu
    }

    private func makeLidMenu() -> NSMenu {
        let menu = makeSubmenu()
        menu.addItem(item(
            L("Kapak kapalıyken uyanık tut", "Stay Awake with the Lid Closed"),
            action: #selector(toggleLid),
            state: session.lidMode ? .on : .off
        ))
        if !session.isOn, cache.sleepDisabled == true {
            menu.addItem(disabledItem(L("Dikkat: sistem uykusu dışarıdan kapalı", "Note: system sleep was disabled elsewhere")))
        }
        menu.addItem(.separator())
        if !cache.loaded {
            menu.addItem(disabledItem(L("Yönetici yardımcısı durumu yükleniyor…", "Checking the privileged helper…")))
        } else if let helper = cache.helper {
            if HelperProtocol.isCurrent(helper) {
                menu.addItem(disabledItem(L("Yardımcı çalışıyor · v\(helper.version ?? "-")", "Helper running · v\(helper.version ?? "-")")))
            } else {
                menu.addItem(disabledItem(L(
                    "Yardımcı eski sürüm · v\(helper.version ?? "-")",
                    "Helper is outdated · v\(helper.version ?? "-")"
                )))
                menu.addItem(item(L("Yardımcıyı güncelle…", "Update Helper…"), action: #selector(installHelper), image: "arrow.triangle.2.circlepath"))
            }
            menu.addItem(item(L("Yardımcıyı kaldır…", "Remove Helper…"), action: #selector(removeHelper), image: "trash"))
        } else if HelperInstaller.daemonPlistExists {
            menu.addItem(disabledItem(L("Yardımcı yanıt vermiyor · tanılamayı kontrol edin", "Helper not responding · check diagnostics")))
            menu.addItem(item(L("Yardımcıyı yeniden kur…", "Reinstall Helper…"), action: #selector(installHelper), image: "lock.shield"))
        } else {
            menu.addItem(disabledItem(L("Yönetici yardımcısı yok", "No privileged helper")))
            menu.addItem(item(L("Yönetici yardımcısını kur…", "Install Privileged Helper…"), action: #selector(installHelper), image: "lock.shield"))
            menu.addItem(disabledItem(L("Kapak modunu her açıp kapattığınızda parola sorulur.", "Without it, lid mode asks for your password each time.")))
        }
        return menu
    }

    private func makeRemoteMenu() -> NSMenu {
        let menu = makeSubmenu()
        let sharing = cache.sharingState
        let canRemote = cache.loaded && (sharing == .running || cache.remoteManagement)
        if !cache.loaded {
            menu.addItem(disabledItem(L("Uzak erişim durumu yükleniyor…", "Checking remote access…")))
        } else if !canRemote {
            menu.addItem(disabledItem(L("Ekran Paylaşımı kapalı — önce açın", "Screen Sharing is off — turn it on first")))
        }
        let vncItem = item(L("Uzaktan bağlanmaya hazırla", "Prepare for Remote Connection"), action: #selector(vncMode), image: "display.slash")
        vncItem.isEnabled = canRemote
        menu.addItem(vncItem)
        menu.addItem(item(L("Ekranı karart", "Turn Display Off"), action: #selector(blackout), image: "moon"))
        menu.addItem(item(L("Ekranı kilitle", "Lock Screen"), action: #selector(lockOnly), image: "lock"))
        menu.addItem(item(L("Ekranı uyandır", "Wake Display"), action: #selector(wakeDisplay), image: "sunrise"))
        menu.addItem(.separator())
        if cache.loaded {
            menu.addItem(disabledItem(sharing.label))
        }
        if session.remoteBlankActive {
            menu.addItem(disabledItem(L("Uzak erişim karartması aktif", "Remote access blackout active")))
        }
        menu.addItem(item(L("Ekran Paylaşımı Ayarları…", "Screen Sharing Settings…"), action: #selector(openSharingSettings), image: "gear"))
        return menu
    }

    private func makeOptionsMenu() -> NSMenu {
        let menu = makeSubmenu()
        menu.addItem(item(
            L("Ekran açık kalsın", "Keep Display Awake"),
            action: #selector(toggleDisplay),
            state: settings.keepDisplayAwake ? .on : .off,
            image: "sun.max"
        ))
        menu.addItem(item(
            L("Oturum kilitlenmesin", "Keep Session Unlocked"),
            action: #selector(toggleUnlocked),
            state: settings.keepSessionUnlocked ? .on : .off,
            image: "lock.open"
        ))
        menu.addItem(item(
            L("Girişte başlat", "Launch at Login"),
            action: #selector(toggleLaunchAtLogin),
            state: settings.launchAtLogin ? .on : .off,
            image: "arrow.right.circle"
        ))

        let batteryItem = item(L("Pil koruması", "Battery Guard"), action: nil, image: "battery.50")
        let batteryMenu = makeSubmenu()
        batteryMenu.addItem(item(
            L("Pil eşiğinde kapat", "Turn Off at Battery Threshold"),
            action: #selector(toggleBatteryCutoff),
            state: settings.batteryCutoffEnabled ? .on : .off
        ))
        batteryMenu.addItem(.separator())
        for percent in [5, 10, 15, 20, 25] {
            let value = Localization.percent(percent)
            let percentItem = item(
                L("\(value) altında", "Below \(value)"),
                action: #selector(setBatteryCutoff(_:)),
                state: settings.batteryCutoffEnabled && settings.batteryCutoffPercent == percent ? .on : .off
            )
            percentItem.tag = percent
            batteryMenu.addItem(percentItem)
        }
        batteryItem.submenu = batteryMenu
        menu.addItem(batteryItem)

        menu.addItem(.separator())
        menu.addItem(disabledItem(L("Kısayol: \(settings.hotkeyPreset.title)", "Shortcut: \(settings.hotkeyPreset.title)")))
        menu.addItem(item(L("Tanılamayı kopyala", "Copy Diagnostics"), action: #selector(copyDiagnostics), image: "doc.on.doc"))
        return menu
    }

    private func addHeader(to menu: NSMenu) {
        let header = NSMenuItem()
        let title = NSMutableAttributedString(
            string: "Pusu",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        title.append(NSAttributedString(
            string: session.isOn ? L("  ·  Açık", "  ·  On") : L("  ·  Kapalı", "  ·  Off"),
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: session.isOn ? NSColor.systemGreen : NSColor.secondaryLabelColor,
            ]
        ))
        header.attributedTitle = title
        header.isEnabled = false
        menu.addItem(header)

        if let battery = session.battery {
            var text = battery.powerLabel
            if let remaining = battery.remainingLabel {
                text += " · \(remaining)"
            }
            menu.addItem(disabledItem(text))
        }

        if cache.loaded, !session.isOn, cache.sleepDisabled == true {
            menu.addItem(disabledItem(L("Sistem uykusu dışarıdan kapatılmış · Pusu kapalı", "System sleep was disabled elsewhere · Pusu is off")))
        }
        if session.lidMode {
            menu.addItem(disabledItem(L("Kapak modu etkin · sistem uyumayacak", "Lid mode on · the system won't sleep")))
        }
        if session.remoteLocked {
            menu.addItem(disabledItem(L("Oturum kilitli · uzak erişim için uyanık", "Session locked · awake for remote access")))
        }
        if let lastError = session.lastError {
            menu.addItem(disabledItem(L("Son hata: \(lastError)", "Last error: \(lastError)")))
        }
    }

    private func item(
        _ title: String,
        action: Selector?,
        key: String = "",
        keyModifiers: NSEvent.ModifierFlags = [.command],
        state: NSControl.StateValue = .off,
        image: String? = nil
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        menuItem.state = state
        if !key.isEmpty {
            menuItem.keyEquivalentModifierMask = keyModifiers
        }
        if let image {
            menuItem.image = symbol(image)
        }
        return menuItem
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        return menuItem
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    // MARK: - Click handling

    @objc private func statusButtonClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
            || !settings.clickTogglesSession
        if wantsMenu {
            showMenu()
        } else {
            actions.toggle()
        }
    }

    /// Menüyü yalnızca gösterirken bağlar; böylece sol tık eylem olarak kalır.
    private func showMenu() {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func showMenuAccessibilityAction() -> Bool {
        showMenu()
        return true
    }

    // MARK: - Actions

    @objc private func toggleActive() { actions.toggle() }

    @objc private func extendSession() { session.extend(by: 15 * 60) }

    @objc private func startPreset(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < PusuDuration.presets.count else { return }
        actions.start(PusuDuration.presets[sender.tag])
    }

    @objc private func customDuration() { actions.customDuration() }

    @objc private func toggleDisplay() { settings.keepDisplayAwake.toggle() }

    @objc private func toggleUnlocked() { settings.keepSessionUnlocked.toggle() }

    @objc private func toggleBatteryCutoff() { settings.batteryCutoffEnabled.toggle() }

    @objc private func setBatteryCutoff(_ sender: NSMenuItem) {
        settings.batteryCutoffPercent = sender.tag
        settings.batteryCutoffEnabled = true
    }

    @objc private func toggleLid() { actions.setLid(!session.lidMode) }

    @objc private func installHelper() { actions.installHelper() }

    @objc private func removeHelper() { actions.removeHelper() }

    @objc private func vncMode() { actions.remoteMode() }

    @objc private func blackout() { actions.blackout() }

    @objc private func lockOnly() { actions.lock() }

    @objc private func wakeDisplay() { actions.wake() }

    @objc private func openSharingSettings() { actions.openSharingSettings() }

    @objc private func toggleLaunchAtLogin() { settings.launchAtLogin.toggle() }

    @objc private func openSettings() { actions.openSettings() }

    @objc private func copyDiagnostics() { actions.copyDiagnostics() }

    @objc private func about() { actions.about() }

    @objc private func checkForUpdates() { actions.checkForUpdates() }

    @objc private func showUpdate() { actions.showUpdate() }

    @objc private func quit() { actions.quit() }
}

/// Global kısayolun menüde gösterilecek karşılığı.
enum HotKeyDisplay {
    static func menuEquivalent(for preset: HotKeyPreset) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        switch preset {
        case .ctrlOptCmdA: return ("a", [.control, .option, .command])
        case .ctrlOptCmdK: return ("k", [.control, .option, .command])
        case .ctrlOptCmdSpace: return (" ", [.control, .option, .command])
        case .optCmdA: return ("a", [.option, .command])
        case .off: return nil
        }
    }
}
