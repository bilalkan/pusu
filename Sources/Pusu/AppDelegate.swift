import AppKit
import Carbon
import Combine
import PusuCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SettingsStore()
    private lazy var session = SessionController(settings: settings, events: EventLog.shared, remoteClients: TernClientWatcher())
    private var statusController: StatusItemController!
    private var settingsWindow: SettingsWindowController!
    private var aboutWindow: AboutWindowController!
    private var hotKeyManager: HotKeyManager!
    private let notifier = Notifier()
    private var cancellables = Set<AnyCancellable>()
    private var commandObserver: NSObjectProtocol?
    private var systemObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var localInputMonitor: Any?
    private var lastCommandID: String?
    private var remoteModeStartedAt = Date.distantPast
    private var pendingCommand: PusuCommand?
    private let helperWatch = HelperWatch(events: EventLog.shared)
    private let helperWatchQueue = DispatchQueue(label: "local.kan.pusu.helper-watch", qos: .utility)
    private var helperWatchTimer: Timer?
    private lazy var updates = UpdateMonitor(settings: settings, currentVersion: CLI.version) { [weak self] title, body in
        self?.notify(title, body)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        HelperProtocol.currentAppBundlePath = AppBundle.url?.path
        // Komut dinleyicisi en başta kaydedilir: `pusu` CLI, uygulama runtime.json'a PID'ini
        // yazınca komut gönderir; o anda dinleyici hazır olmalı.
        commandObserver = DistributedNotificationCenter.default().addObserver(
            forName: .pusuCommand,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleDistributed(note)
        }
        installMainMenu()
        loadAppIcon()
        EventLog.shared.prune()
        EventLog.shared.record("Pusu \(CLI.version) started")
        // Önceki çalıştırma ekran karartılmışken beklenmedik şekilde kapandıysa parlaklığı geri getir.
        if (session.remote as? RemoteController)?.restoreAfterCrashIfNeeded() == true {
            EventLog.shared.record("Display brightness restored after an unexpected quit")
        }
        observeSystemEvents()
        startHelperWatch()

        session.onEvent = { [weak self] event in
            self?.handle(event: event)
        }
        session.$remoteBlankActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in self?.setLocalInputMonitor(active) }
            .store(in: &cancellables)

        statusController = StatusItemController(
            session: session,
            settings: settings,
            updates: updates,
            actions: makeStatusActions()
        )
        settingsWindow = SettingsWindowController(
            settings: settings,
            session: session,
            history: session.history,
            updates: updates,
            actions: makeSettingsActions()
        )
        aboutWindow = AboutWindowController()

        hotKeyManager = HotKeyManager { [weak self] in
            self?.session.toggle()
        }
        if !hotKeyManager.register(settings.hotkeyPreset) {
            let failed = settings.hotkeyPreset.title
            settings.hotkeyPreset = .off
            showError(
                title: L("Kısayol atanamadı", "Could not set the shortcut"),
                message: L(
                    "\(failed) başka bir uygulama tarafından kullanılıyor olabilir. Kısayol kapatıldı.",
                    "\(failed) may be in use by another app. The shortcut was turned off."
                )
            )
        }

        settings.$hotkeyPreset
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] preset in
                guard let self else { return }
                if !self.hotKeyManager.register(preset) {
                    self.showError(
                        title: L("Kısayol atanamadı", "Could not set the shortcut"),
                        message: L(
                            "\(preset.title) kaydedilemedi. Başka bir uygulamayla çakışıyor olabilir.",
                            "\(preset.title) could not be registered. It may conflict with another app."
                        )
                    )
                    self.settings.hotkeyPreset = .off
                }
            }
            .store(in: &cancellables)

        settings.$launchAtLogin
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                do {
                    try LaunchAtLogin.setEnabled(enabled)
                } catch {
                    NSLog("Pusu login item error: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.settings.launchAtLogin = LaunchAtLogin.isEnabled()
                        self.showError(title: L("Girişte başlat", "Open at login"), message: error.localizedDescription)
                    }
                }
            }
            .store(in: &cancellables)

        settings.$language
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.installMainMenu()
                self?.settingsWindow.refreshTitle()
                self?.aboutWindow.refreshTitle()
            }
            .store(in: &cancellables)

        LaunchAtLogin.migrateLegacy()
        LaunchAtLogin.sync(settings.launchAtLogin)

        if HelperInstaller.legacyArtifactsExist {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) { [weak self] in
                do {
                    try HelperInstaller.migrateLegacyAwakeHelper()
                    DispatchQueue.main.async {
                        self?.notify(
                            L("Eski yardımcı temizlendi", "Old helper removed"),
                            L("SleepDisabled güvenli değere döndürüldü.", "SleepDisabled was restored to a safe value.")
                        )
                    }
                } catch {
                    NSLog("Pusu legacy helper migration error: \(error.localizedDescription)")
                }
            }
        }


        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        pendingCommand = CLI.pendingCommand()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            if let command = self.pendingCommand {
                self.handle(command: command, source: .external)
                self.pendingCommand = nil
            } else if !UserDefaults.standard.bool(forKey: "pusu.didShowIntro") {
                UserDefaults.standard.set(true, forKey: "pusu.didShowIntro")
                self.showWelcome()
            }
            // Güncelleme izni bir kez sorulur (yeni kurulumda karşılamadan hemen sonra).
            self.updates.askForPermissionIfNeeded()
            self.updates.start()
        }

        if settings.autoStartOnLaunch, pendingCommand == nil {
            session.start(settings.defaultDuration)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if session.lidMode, !session.lid.helperResponding {
            AppActivation.activate()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("Kapak modu açık", "Lid mode is on")
            alert.informativeText = L("""
            Yönetici yardımcısı kurulu değil. Çıkarken SleepDisabled ayarını sıfırlamak için yönetici parolası gerekir.

            Uyku kapalı kalırsa geri almak için: sudo pmset -a disablesleep 0
            """, """
            The privileged helper is not installed. Resetting SleepDisabled on quit requires your administrator password.

            If sleep stays disabled, undo it with: sudo pmset -a disablesleep 0
            """)
            alert.addButton(withTitle: L("Kapak modunu kapat ve çık", "Turn off lid mode and quit"))
            alert.addButton(withTitle: L("Uyku kapalı kalsın (önerilmez)", "Keep sleep disabled (not recommended)"))
            alert.addButton(withTitle: L("İptal", "Cancel"))

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                do {
                    try session.lid.setEnabled(false, allowPrompt: true)
                    session.shutdown()
                    return .terminateNow
                } catch {
                    if !isUserCancelled(error) {
                        showError(title: L("Kapak modu kapatılamadı", "Could not turn off lid mode"), message: error.localizedDescription)
                    }
                    return .terminateCancel
                }
            case .alertSecondButtonReturn:
                session.shutdown()
                return .terminateNow
            default:
                return .terminateCancel
            }
        }

        session.shutdown()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.shutdown()
        EventLog.shared.record("Pusu quit")
        for (center, observer) in systemObservers {
            center.removeObserver(observer)
        }
        if let commandObserver {
            DistributedNotificationCenter.default().removeObserver(commandObserver)
        }
        hotKeyManager?.unregister()
    }

    // MARK: - Actions

    private func makeStatusActions() -> StatusActions {
        StatusActions(
            toggle: { [weak self] in self?.session.toggle() },
            start: { [weak self] duration in self?.session.start(duration) },
            stop: { [weak self] in self?.session.stop() },
            customDuration: { [weak self] in self?.askCustomDuration() },
            setLid: { [weak self] enabled in self?.setLid(enabled) },
            installHelper: { [weak self] in self?.installHelper() },
            removeHelper: { [weak self] in self?.removeHelper() },
            remoteMode: { [weak self] in
                self?.beginRemoteMode(lock: self?.settings.remoteLockOnBlackout ?? true)
            },
            blackout: { [weak self] in self?.session.enterRemoteMode(lock: false) },
            lock: { [weak self] in _ = self?.session.remote.lockScreen() },
            wake: { [weak self] in self?.session.exitRemoteMode() },
            openSharingSettings: { [weak self] in self?.openSharingSettings() },
            openSettings: { [weak self] in self?.showSettings() },
            copyDiagnostics: { [weak self] in self?.copyDiagnostics() },
            about: { [weak self] in self?.showAbout() },
            checkForUpdates: { [weak self] in self?.updates.check(userInitiated: true) },
            showUpdate: { [weak self] in self?.updates.presentUpdate() },
            quit: { NSApp.terminate(nil) }
        )
    }

    private func makeSettingsActions() -> SettingsActions {
        SettingsActions(
            toggle: { [weak self] in self?.session.toggle() },
            start: { [weak self] duration in self?.session.start(duration) },
            stop: { [weak self] in self?.session.stop() },
            setLid: { [weak self] enabled in self?.setLid(enabled) },
            installHelper: { [weak self] in self?.installHelper() },
            removeHelper: { [weak self] in self?.removeHelper() },
            remoteMode: { [weak self] in
                self?.beginRemoteMode(lock: self?.settings.remoteLockOnBlackout ?? true)
            },
            blackout: { [weak self] in self?.session.enterRemoteMode(lock: false) },
            lock: { [weak self] in _ = self?.session.remote.lockScreen() },
            wake: { [weak self] in self?.session.exitRemoteMode() },
            openSharingSettings: { [weak self] in self?.openSharingSettings() },
            copyDiagnostics: { [weak self] in self?.copyDiagnostics() },
            about: { [weak self] in self?.showAbout() },
            checkForUpdates: { [weak self] in self?.updates.check(userInitiated: true) },
            showUpdate: { [weak self] in self?.updates.presentUpdate() }
        )
    }

    private func setLid(_ enabled: Bool, allowPrompt: Bool = true) {
        if enabled, allowPrompt, !session.lid.helperAvailable, !session.lidMode {
            guard confirmLidMode() else { return }
        }

        session.setLidModeAsync(enabled, allowPrompt: allowPrompt) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result, !self.isUserCancelled(error) {
                self.showError(title: L("Kapak modu", "Lid mode"), message: error.localizedDescription)
            }
        }
    }

    private func confirmLidMode() -> Bool {
        AppActivation.activate()
        let alert = NSAlert()
        alert.messageText = L("Kapak modu yönetici izni ister", "Lid mode needs administrator permission")
        alert.informativeText = L("""
        Pusu, kapak kapalıyken de sistemin uyumaması için macOS'ta `pmset -a disablesleep 1` ayarını yapar.

        Bu ayar pilde ek tüketim ve ısınma yaratabilir. Kapatmak için kapak modunu kapatmanız veya `sudo pmset -a disablesleep 0` çalıştırmanız yeterlidir.

        Yönetici yardımcısını kurarsanız (Ayarlar › Sistem) parola bir daha sorulmaz.

        Devam edilsin mi?
        """, """
        To keep the system awake with the lid closed, Pusu sets `pmset -a disablesleep 1` on macOS.

        This can use more battery and make the Mac warmer. To undo it, turn off lid mode or run `sudo pmset -a disablesleep 0`.

        Install the privileged helper (Settings › System) and you won't be asked for your password again.

        Continue?
        """)
        alert.addButton(withTitle: L("Devam Et", "Continue"))
        alert.addButton(withTitle: L("Vazgeç", "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func isUserCancelled(_ error: Error) -> Bool {
        if case HelperError.adminCancelled = error { return true }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }

    private func installHelper() {
        guard let helperURL = AppBundle.helperURL else {
            NotificationCenter.default.post(name: .pusuHelperChanged, object: nil)
            showError(
                title: L("Yardımcı bulunamadı", "Helper not found"),
                message: L(
                    "Uygulama paketinde pusu-helper yok. Geliştirme derlemesinde scripts/build.sh çalıştırın.",
                    "pusu-helper is missing from the app bundle. For a development build, run scripts/build.sh."
                )
            )
            return
        }

        AppActivation.activate()
        let installed = HelperClient.ping(timeout: 0.6)
        let isUpdate = installed != nil && !HelperProtocol.isCurrent(installed)
        let confirm = NSAlert()
        confirm.messageText = isUpdate
            ? L("Yönetici yardımcısı güncellensin mi?", "Update the privileged helper?")
            : L("Yönetici yardımcısı kurulsun mu?", "Install the privileged helper?")
        confirm.informativeText = L("""
        Pusu, yalnızca `pmset -a disablesleep` ayarını değiştirmek için root yetkili küçük bir yardımcı kurar:
        \(HelperProtocol.installedBinaryPath)
        \(HelperProtocol.daemonPlistPath)

        Yardımcı yalnızca admin grubunun erişebildiği bir soketten sabit komutlar (ping, status, lid-on, lid-off) kabul eder. Pusu kaldırılır ya da taşınırsa (uygulama yaklaşık 15 dakika ortada olmazsa) uyku ayarını geri yükleyip kendini kaldırır. Elle kaldırmak için Ayarlar › Sistem'deki "Yardımcıyı kaldır…" düğmesini veya `pusu uninstall-helper` komutunu kullanabilirsiniz.
        """, """
        Pusu installs a small root helper whose only job is to change `pmset -a disablesleep`:
        \(HelperProtocol.installedBinaryPath)
        \(HelperProtocol.daemonPlistPath)

        The helper accepts only fixed commands (ping, status, lid-on, lid-off) over a socket that only the admin group can reach. If Pusu is removed or moved (the app is gone for about 15 minutes), it restores the sleep setting and removes itself. To remove it by hand, use "Remove Helper…" in Settings › System or run `pusu uninstall-helper`.
        """)
        confirm.addButton(withTitle: isUpdate ? L("Güncelle", "Update") : L("Kur", "Install"))
        confirm.addButton(withTitle: L("İptal", "Cancel"))
        guard confirm.runModal() == .alertFirstButtonReturn else {
            NotificationCenter.default.post(name: .pusuHelperChanged, object: nil)
            return
        }

        helperWatch.beginChange()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { self?.helperWatch.endChange() }
            do {
                try HelperInstaller.install(helperBinary: helperURL, expectedSHA256: AppBundle.helperSHA256, appBundlePath: AppBundle.url?.path)
                EventLog.shared.record("Helper \(isUpdate ? "updated" : "installed") (version \(HelperProtocol.version))")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .pusuHelperChanged, object: nil)
                    self?.notify(
                        isUpdate ? L("Yardımcı güncellendi", "Helper updated") : L("Yardımcı kuruldu", "Helper installed"),
                        L("Kapak modu artık parola sormadan çalışır.", "Lid mode now works without asking for your password.")
                    )
                    self?.session.refreshLidState()
                }
            } catch {
                EventLog.shared.record("Helper install failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .pusuHelperChanged, object: nil)
                    if !(self?.isUserCancelled(error) ?? false) {
                        self?.showError(title: L("Yardımcı kurulamadı", "Could not install the helper"), message: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func removeHelper() {
        AppActivation.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Yönetici yardımcısı kaldırılsın mı?", "Remove the privileged helper?")
        alert.informativeText = L(
            "Kapak modu yardımcı üzerinden çalışmayı durduracak. Mevcut SleepDisabled ayarı geri alınacak.",
            "Lid mode will stop working through the helper. The current SleepDisabled setting will be restored."
        )
        alert.addButton(withTitle: L("Kaldır", "Remove"))
        alert.addButton(withTitle: L("İptal", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else {
            NotificationCenter.default.post(name: .pusuHelperChanged, object: nil)
            return
        }

        if session.lidMode {
            try? session.lid.setEnabled(false, allowPrompt: true)
            session.stop(reason: .user)
        }

        helperWatch.beginChange()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { self?.helperWatch.endChange() }
            do {
                try HelperInstaller.uninstall()
                EventLog.shared.record("Helper removed (from Pusu)")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .pusuHelperChanged, object: nil)
                    self?.notify(
                        L("Yardımcı kaldırıldı", "Helper removed"),
                        L("Kapak modu artık her seferinde yönetici parolası ister.", "Lid mode will now ask for your administrator password each time.")
                    )
                    self?.session.refreshLidState()
                }
            } catch {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .pusuHelperChanged, object: nil)
                    if !(self?.isUserCancelled(error) ?? false) {
                        self?.showError(title: L("Yardımcı kaldırılamadı", "Could not remove the helper"), message: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func askCustomDuration() {
        AppActivation.activate()
        let alert = NSAlert()
        alert.messageText = L("Özel süre", "Custom duration")
        alert.informativeText = L(
            "Pusu ne kadar açık kalsın? Dakika (90) ya da 1h30m, 2h gibi yazabilirsiniz.",
            "How long should Pusu stay on? Enter minutes (90) or something like 1h30m or 2h."
        )
        alert.addButton(withTitle: L("Başlat", "Start"))
        alert.addButton(withTitle: L("İptal", "Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        field.placeholderString = L("ör. 90", "e.g. 90")
        field.stringValue = "90"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let minutes = CommandParser.parseDuration(field.stringValue) else {
            NSSound.beep()
            return
        }
        session.start(PusuDuration(minutes: minutes))
    }

    private func copyDiagnostics() {
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = session.diagnostics(appVersion: CLI.version)
            DispatchQueue.main.async {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                self?.notify(
                    L("Tanılama kopyalandı", "Diagnostics copied"),
                    L("Teknik bilgiler panoya aktarıldı.", "Technical details are on the clipboard.")
                )
            }
        }
    }

    private func openSharingSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Sharing-Settings.extension",
            "x-apple.systempreferences:com.apple.preferences.sharing",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func showAbout() {
        aboutWindow.show()
    }

    private func showWelcome() {
        AppActivation.activate()
        let alert = NSAlert()
        alert.messageText = L("Pusu menü çubuğunda", "Pusu lives in the menu bar")
        let shortcut = settings.hotkeyPreset == .off
            ? ""
            : L(" \(settings.hotkeyPreset.title) ile açıp kapatabilirsiniz.", " Press \(settings.hotkeyPreset.title) to turn it on or off.")
        alert.informativeText = L("""
        Menü çubuğundaki anahtar deliği simgesine tıklayarak Pusu'yu açıp kapatın; sağ tıkla menüyü açın.\(shortcut)

        Kapak kapalıyken uyanık kalmak (kapak modu) yönetici izni ister. İsterseniz Ayarlar › Sistem'den küçük bir yardımcı kurup parolayı tek seferle sınırlayabilirsiniz.
        """, """
        Click the keyhole icon in the menu bar to turn Pusu on or off; right-click it for the menu.\(shortcut)

        Staying awake with the lid closed (lid mode) needs administrator permission. You can install a small helper from Settings › System so you're only asked once.
        """)
        alert.addButton(withTitle: L("Pusu'yu Başlat", "Start Pusu"))
        alert.addButton(withTitle: L("Ayarlar…", "Settings…"))
        alert.addButton(withTitle: L("Daha Sonra", "Later"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            session.start(settings.defaultDuration)
        case .alertSecondButtonReturn:
            showSettings()
        default:
            break
        }
    }

    private func beginRemoteMode(lock: Bool) {
        let remote = session.remote
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sharing = remote.screenSharingState()
            let remoteManagement = remote.remoteManagementRunning()
            DispatchQueue.main.async {
                guard let self else { return }
                if sharing == .running || remoteManagement || TernClientWatcher.isInstalled {
                    self.session.enterRemoteMode(lock: lock)
                    return
                }

                AppActivation.activate()
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L("Ekran Paylaşımı kapalı", "Screen Sharing is off")
                alert.informativeText = lock
                    ? L(
                        "Uzak erişim modu ekranı karartır ve oturumu kilitler. Ekran Paylaşımı kapalıyken bu Mac'e uzaktan bağlanamazsınız. Yine de başlatılsın mı?",
                        "Remote access mode turns the display off and locks the session. With Screen Sharing off you won't be able to connect to this Mac remotely. Start anyway?"
                    )
                    : L(
                        "Uzak erişim modu ekranı karartır. Ekran Paylaşımı kapalıyken bu Mac'e uzaktan bağlanamazsınız. Yine de başlatılsın mı?",
                        "Remote access mode turns the display off. With Screen Sharing off you won't be able to connect to this Mac remotely. Start anyway?"
                    )
                alert.addButton(withTitle: L("Ekran Paylaşımı Ayarları…", "Screen Sharing Settings…"))
                alert.addButton(withTitle: L("Yine de Başlat", "Start Anyway"))
                alert.addButton(withTitle: L("İptal", "Cancel"))
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    self.openSharingSettings()
                case .alertSecondButtonReturn:
                    self.session.enterRemoteMode(lock: lock)
                default:
                    break
                }
            }
        }
    }

    @objc private func menuOpenSettings() {
        showSettings()
    }

    @objc private func menuAbout() {
        showAbout()
    }

    @objc private func menuCheckForUpdates() {
        updates.check(userInitiated: true)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let about = NSMenuItem(title: L("Pusu Hakkında", "About Pusu"), action: #selector(menuAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        let updatesItem = NSMenuItem(title: L("Güncellemeleri Denetle…", "Check for Updates…"), action: #selector(menuCheckForUpdates), keyEquivalent: "")
        updatesItem.target = self
        appMenu.addItem(updatesItem)
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: L("Ayarlar…", "Settings…"), action: #selector(menuOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: L("Pusu'dan Çık", "Quit Pusu"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: L("Düzen", "Edit"))
        editMenu.addItem(withTitle: L("Geri Al", "Undo"), action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        editMenu.addItem(withTitle: L("Kes", "Cut"), action: NSSelectorFromString("cut:"), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Kopyala", "Copy"), action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Yapıştır", "Paste"), action: NSSelectorFromString("paste:"), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Tümünü Seç", "Select All"), action: NSSelectorFromString("selectAll:"), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: L("Pencere", "Window"))
        windowMenu.addItem(withTitle: L("Kapat", "Close"), action: NSSelectorFromString("performClose:"), keyEquivalent: "w")
        windowMenu.addItem(withTitle: L("Küçült", "Minimize"), action: NSSelectorFromString("performMiniaturize:"), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func notify(_ title: String, _ body: String) {
        guard settings.notificationsEnabled else { return }
        notifier.send(title: title, body: body)
    }

    private func showSettings() {
        settingsWindow?.show()
    }

    private func showError(title: String, message: String) {
        AppActivation.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L("Tamam", "OK"))
        alert.runModal()
    }

    private func loadAppIcon() {
        guard let url = Bundle.main.url(forResource: "Pusu", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = image
    }

    // MARK: - Events and commands

    private func handle(event: PusuEvent) {
        switch event {
        case .started:
            NotificationCenter.default.post(name: .pusuStateChanged, object: nil)
        case .stopped:
            NotificationCenter.default.post(name: .pusuStateChanged, object: nil)
        case .lidChanged(let enabled):
            NotificationCenter.default.post(name: .pusuStateChanged, object: nil)
            notify(
                enabled ? L("Kapak modu açık", "Lid mode on") : L("Kapak modu kapalı", "Lid mode off"),
                enabled
                    ? L("Kapak kapalıyken sistem uyanık kalacak.", "The system will stay awake with the lid closed.")
                    : L("Sistem normal uyku davranışına döndü.", "The system is back to its normal sleep behavior.")
            )
        case .remoteMode(let active, let locked, let slept):
            NotificationCenter.default.post(name: .pusuStateChanged, object: nil)
            if active {
                var parts: [String] = []
                if session.remoteVirtualDisplay {
                    parts.append(L("Kapak kapalı: uzak bağlantılar için sanal ekran açık.", "Lid closed: a virtual display is on for remote connections."))
                } else if session.remotePanelDark {
                    parts.append(L("Ekran açık ama karanlık.", "The display is on but dark."))
                } else if slept {
                    parts.append(L("Ekran uyudu; Tern bağlanınca karanlık olarak uyanır.", "The display is asleep; it wakes up dark when Tern connects."))
                } else {
                    parts.append(L("Ekran kapatılamadı.", "The display could not be turned off."))
                }
                if locked { parts.append(L("Oturum kilitli.", "The session is locked.")) }
                parts.append(L("Mac'in başındaysan kilidi açıp tıklaman yeterli.", "At the Mac, unlock and click to end it."))
                notify(L("Uzak erişim modu", "Remote access mode"), parts.joined(separator: " "))
            } else {
                notify(L("Uzak erişim modu kapandı", "Remote access mode ended"), L("Ekran normale döndü.", "The display is back to normal."))
            }
        case .message(let title, let body):
            notify(title, body)
        case .error(let message):
            notify(L("Pusu · Uyarı", "Pusu · Warning"), message)
        case .tick, .batteryUpdated:
            break
        }
    }

    private func handleDistributed(_ note: Notification) {
        guard let raw = note.userInfo?["command"] as? String else { return }
        let minutes = note.userInfo?["minutes"] as? Int
        guard let command = PusuCommand(wireName: raw, minutes: minutes),
              CommandParser.isAllowedFromDistributedNotification(command)
        else { return }
        // CLI, onay görmezse aynı komutu aynı kimlikle yeniden gönderir: ikinci kez işleme.
        if let id = note.userInfo?["id"] as? String, CommandDelivery.isValidID(id) {
            // Uygulama komutu yavaş işlediyse CLI aynı kimlikle yeniden sorar: onayı yinele.
            guard id != lastCommandID else {
                CommandDelivery.writeAck(id)
                return
            }
            lastCommandID = id
            handle(command: command, source: .external)
            CommandDelivery.writeAck(id)
            return
        }
        handle(command: command, source: .external)
    }

    /// Komutun nereden geldiği.
    enum CommandSource {
        /// Menü, kısayol, Ayarlar: kullanıcı doğrudan istedi.
        case user
        /// `pusu` komut satırı, başka bir uygulama, açılış argümanı.
        case external
        /// `pusu://` bağlantısı (bir web sayfası da açabilir).
        case url

        var logLabel: String {
            switch self {
            case .user: return "menu/shortcut"
            case .external: return "command line"
            case .url: return "pusu:// link"
            }
        }

        /// Dışarıdan gelen komutlar asla yönetici parolası penceresi açmaz; yoksa kötü niyetli
        /// bir süreç ya da sayfa Pusu adına inandırıcı bir parola isteği tetikleyebilir.
        var mayPromptForAdmin: Bool { self == .user }

        /// URL ile başlatılan oturumların üst sınırı.
        var maxDuration: TimeInterval? {
            self == .url ? TimeInterval(CommandParser.maxURLMinutes * 60) : nil
        }
    }

    private func handle(command: PusuCommand, source: CommandSource = .user) {
        let minutes = command.minutes.map { " \($0)m" } ?? ""
        EventLog.shared.record("Command: \(command.wireName)\(minutes) (from \(source.logLabel))")
        switch command {
        case .toggle:
            session.toggle(allowLidPrompt: source.mayPromptForAdmin, maxDuration: source.maxDuration)
        case .on(let minutes):
            let requested = minutes.map { PusuDuration(minutes: $0) } ?? settings.defaultDuration
            session.start(SessionController.capped(requested, to: source.maxDuration))
        case .off:
            session.stop(allowLidPrompt: source.mayPromptForAdmin)
        case .blackout:
            session.enterRemoteMode(lock: false)
        case .vnc:
            beginRemoteMode(lock: settings.remoteLockOnBlackout)
        case .lock:
            _ = session.remote.lockScreen()
        case .wake:
            session.exitRemoteMode()
        case .settings:
            showSettings()
        case .diagnostics:
            copyDiagnostics()
        case .lid(let on):
            let target = on ?? !session.lidMode
            guard target != session.lidMode else { return }
            // Dışarıdan: açmak güncel yardımcı ister, kapatmak yanıt veren her yardımcıyla olur.
            // (CLI bu durumu zaten kendisi kontrol edip terminale yazar.)
            let canRun = target ? session.lid.helperAvailable : session.lid.helperResponding
            if !source.mayPromptForAdmin, !canRun {
                let error: HelperError = target ? .helperNeededForExternalLidOn : .promptNotAllowed
                notify(L("Kapak modu", "Lid mode"), error.localizedDescription)
                return
            }
            setLid(target, allowPrompt: source.mayPromptForAdmin)
        }
    }

    /// Uzak erişim modunda Mac'in kendi trackpad'i/klavyesi kullanılırsa (Mac başında biri varsa)
    /// mod biter. Uzaktan (Tern, Ekran Paylaşımı) gelen olaylar, onları gönderen sürecin
    /// numarasını taşır; donanımdan gelenlerde bu numara 0'dır. Kilit ekranındayken macOS
    /// uygulamalara olay göstermez: Mac başındaki kişi önce kilidi açar, sonra tıklar.
    private func setLocalInputMonitor(_ active: Bool) {
        if let localInputMonitor {
            NSEvent.removeMonitor(localInputMonitor)
            self.localInputMonitor = nil
        }
        guard active else { return }
        remoteModeStartedAt = Date()
        // İmleç hareketi sayılmaz (masaya çarpma vb.); tıklama, kaydırma ve tuşlar sayılır.
        localInputMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
        ) { [weak self] event in
            guard let self, let cgEvent = event.cgEvent else { return }
            // Modu başlatan tıklamanın devamı sayılmasın.
            guard Date().timeIntervalSince(self.remoteModeStartedAt) > 3 else { return }
            guard cgEvent.getIntegerValueField(.eventSourceUnixProcessID) == 0 else { return }
            self.session.localInputDetected()
        }
    }

    // MARK: - Helper watch

    /// Yardımcı Pusu dışında kaybolursa (ör. eski bir Homebrew cask'ı onu sildiyse) günlüğe yazar
    /// ve bir kez bildirir. Açılışta, 5 dakikada bir ve uykudan uyanınca bakılır.
    private func startHelperWatch() {
        scheduleHelperCheck(after: 5)
        let timer = Timer(timeInterval: HelperWatch.interval, repeats: true) { [weak self] _ in
            self?.scheduleHelperCheck(after: 0)
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        helperWatchTimer = timer
    }

    private func scheduleHelperCheck(after delay: TimeInterval) {
        helperWatchQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let outcome = self.helperWatch.check()
            DispatchQueue.main.async { self.handleHelperWatch(outcome) }
        }
    }

    private func handleHelperWatch(_ outcome: HelperWatch.Outcome) {
        switch outcome {
        case .none:
            break
        case .needsConfirmation:
            scheduleHelperCheck(after: HelperWatch.confirmDelay)
        case .missing(let problem):
            NotificationCenter.default.post(name: .pusuHelperChanged, object: nil)
            switch problem {
            case .removed:
                notify(
                    L("Yönetici yardımcısı kaldırılmış", "The privileged helper was removed"),
                    L(
                        "Kapak modu artık parola isteyecek. Ayarlar › Sistem'den yeniden kurabilirsiniz.",
                        "Lid mode will ask for your password. You can reinstall it from Settings › System."
                    )
                )
            case .notResponding:
                notify(
                    L("Yönetici yardımcısı yanıt vermiyor", "The privileged helper is not responding"),
                    L(
                        "Kapak modu parola isteyebilir. Ayarlar › Sistem'den yeniden kurmayı deneyin.",
                        "Lid mode may ask for your password. Try reinstalling it from Settings › System."
                    )
                )
            }
        case .restored:
            NotificationCenter.default.post(name: .pusuHelperChanged, object: nil)
        }
    }

    /// Ekran, kilit ve uyku olaylarını günlüğe yazar. Uzaktan bağlanılamadığında "o sırada ekran
    /// açık mıydı, oturum kilitli miydi?" sorusunu yanıtlamak için.
    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        let workspaceEvents: [(Notification.Name, String)] = [
            (NSWorkspace.screensDidSleepNotification, "Display went to sleep"),
            (NSWorkspace.screensDidWakeNotification, "Display woke up"),
            (NSWorkspace.willSleepNotification, "System is going to sleep"),
            (NSWorkspace.didWakeNotification, "System woke up"),
            (NSWorkspace.sessionDidResignActiveNotification, "User session became inactive (switched away)"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "User session became active"),
        ]
        for (name, text) in workspaceEvents {
            let observer = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                EventLog.shared.record(text)
                if name == NSWorkspace.didWakeNotification {
                    self?.scheduleHelperCheck(after: 10)
                }
                if name == NSWorkspace.willSleepNotification {
                    self?.session.systemWillSleep()
                }
            }
            systemObservers.append((workspace, observer))
        }

        let distributed = DistributedNotificationCenter.default()
        let lockEvents: [(String, String)] = [
            ("com.apple.screenIsLocked", "Screen locked"),
            ("com.apple.screenIsUnlocked", "Screen unlocked"),
        ]
        for (name, text) in lockEvents {
            let observer = distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                EventLog.shared.record(text)
            }
            systemObservers.append((distributed, observer))
        }
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string),
              let command = CommandParser.parse(url: url)
        else { return }
        handle(command: command, source: .url)
    }
}
