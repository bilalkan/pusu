import AppKit
import Darwin
import PusuCore

extension Notification.Name {
    static let pusuCommand = Notification.Name("local.kan.pusu.command")
}

enum CLI {
    static let bundleIdentifier = "local.kan.pusu"

    /// Info.plist'teki sürüm; geliştirme derlemesinde (paket dışı) sabit değere düşer.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    /// Terminalden gelen bir komutu işler. `true` dönerse süreç hemen çıkmalıdır.
    static func handleEarly() -> Bool {
        let arguments = CommandLine.arguments
        let args = Array(arguments.dropFirst())
        let first = args.first

        if first == "version" || args.contains("--version") {
            print("Pusu \(version)")
            return true
        }

        if first == "help" || args.contains("--help") || args.contains("-h") {
            print(helpText)
            return true
        }

        if first == "install-helper" || args.contains("--install-helper") {
            installHelper()
            return true
        }

        if first == "uninstall-helper" || args.contains("--uninstall-helper") {
            uninstallHelper()
            return true
        }

        if first == "status" || args.contains("--status") {
            printStatus()
            return true
        }

        if first == "diagnostics" || args.contains("--diagnostics") {
            printDiagnostics()
            return true
        }

        if let first, !first.hasPrefix("-"), CommandParser.parse(arguments) == nil {
            fputs(L("Bilinmeyen komut: \(first)\n", "Unknown command: \(first)\n"), stderr)
            fputs(L("Kullanım için: pusu help\n", "For usage: pusu help\n"), stderr)
            exit(64)
        }

        let command = CommandParser.parse(arguments)

        if let command, appIsRunning() {
            waitUntilAppIsReady()
            post(command)
            return true
        }

        // Terminalden çağrıldıysa uygulamayı terminale bağlamadan LaunchServices ile başlat;
        // komut, yeni sürecin argümanı olarak tüketilir.
        if launchedFromTerminal, !args.contains("--foreground"), let bundle = AppBundle.url {
            launchDetached(bundle: bundle, arguments: args)
            return true
        }

        return false
    }

    static func pendingCommand() -> PusuCommand? {
        CommandParser.parse(CommandLine.arguments)
    }

    static func post(_ command: PusuCommand) {
        var userInfo: [String: Any] = ["command": command.wireName]
        if let minutes = command.minutes {
            userInfo["minutes"] = minutes
        }
        DistributedNotificationCenter.default().postNotificationName(
            .pusuCommand,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }

    static func appIsRunning() -> Bool {
        let me = getpid()
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { $0.processIdentifier != me && !$0.isTerminated }
        if running { return true }
        // Paketlenmemiş geliştirme derlemesi: runtime.json'daki PID'e bak.
        guard let state = RuntimeStateStore.read(), state.pid != me else { return false }
        return RuntimeStateStore.appIsRunning(pid: state.pid)
    }

    // MARK: - Private

    /// Uygulama yeni açılıyorsa dağıtık bildirimi dinlemeye başlamadan gönderilen komut
    /// kaybolur. Uygulama hazır olduğunda runtime.json'a kendi PID'ini yazar; onu bekle.
    private static func waitUntilAppIsReady(timeout: TimeInterval = 3) {
        let me = getpid()
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.processIdentifier != me && !$0.isTerminated })
        else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if RuntimeStateStore.read()?.pid == app.processIdentifier {
                // Gözlemci, durum yazıldıktan sonra aynı açılış adımında kaydedilir.
                Thread.sleep(forTimeInterval: 0.2)
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private static var launchedFromTerminal: Bool {
        isatty(STDIN_FILENO) != 0 || isatty(STDOUT_FILENO) != 0
    }

    private static func launchDetached(bundle: URL, arguments: [String]) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.activates = false
        configuration.createsNewApplicationInstance = false

        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, error in
            failure = error
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 15) == .timedOut {
            fputs(L("Pusu başlatılamadı: zaman aşımı.\n", "Could not launch Pusu: timed out.\n"), stderr)
            exit(1)
        }
        if let failure {
            fputs(L("Pusu başlatılamadı: \(failure.localizedDescription)\n", "Could not launch Pusu: \(failure.localizedDescription)\n"), stderr)
            exit(1)
        }
    }

    private static var helpText: String {
        L("""
        Pusu \(version) — Mac'in uyanık kalmasını sağlayan menü çubuğu uygulaması

        Kullanım:
          pusu                     Menü çubuğu uygulamasını başlat
          pusu on [süre]           Aç (60, 90m, 2h, 1h30m; boşsa varsayılan süre)
          pusu off                 Kapat
          pusu toggle              Aç/kapat
          pusu status              Çalışma durumunu JSON olarak yazdır
          pusu vnc                 Uzaktan bağlanmaya hazırla (karart + isteğe bağlı kilit)
          pusu lid [on|off]        Kapak modunu aç/kapat (argümansız: değiştir)
          pusu blackout            Ekranı karart, kilitleme
          pusu lock                Ekranı kilitle
          pusu wake                Ekranı uyandır
          pusu settings            Ayarlar penceresini aç
          pusu diagnostics         Tanılama bilgisini yazdır
          pusu install-helper      Yönetici yardımcısını kur (parola sorar)
          pusu uninstall-helper    Yönetici yardımcısını kaldır
          pusu version             Sürüm

        URL şeması: pusu://on?minutes=60, pusu://off, pusu://toggle
        """, """
        Pusu \(version) — a menu bar app that keeps your Mac awake

        Usage:
          pusu                     Launch the menu bar app
          pusu on [duration]       Turn on (60, 90m, 2h, 1h30m; default duration if empty)
          pusu off                 Turn off
          pusu toggle              Toggle on/off
          pusu status              Print the runtime state as JSON
          pusu vnc                 Prepare for remote access (blackout + optional lock)
          pusu lid [on|off]        Turn lid mode on/off (no argument: toggle)
          pusu blackout            Turn the display off without locking
          pusu lock                Lock the screen
          pusu wake                Wake the display
          pusu settings            Open the Settings window
          pusu diagnostics         Print diagnostics
          pusu install-helper      Install the privileged helper (asks for your password)
          pusu uninstall-helper    Remove the privileged helper
          pusu version             Print the version

        URL scheme: pusu://on?minutes=60, pusu://off, pusu://toggle
        """)
    }

    private static func installHelper() {
        guard let url = AppBundle.helperURL else {
            fputs(L("pusu-helper bulunamadı. Pusu.app içinden çalıştırın.\n", "pusu-helper not found. Run this from inside Pusu.app.\n"), stderr)
            exit(4)
        }
        do {
            try HelperInstaller.install(helperBinary: url, expectedSHA256: AppBundle.helperSHA256)
            print(L("Yönetici yardımcısı kuruldu.", "Privileged helper installed."))
        } catch {
            fputs(L("Kurulum başarısız: \(error.localizedDescription)\n", "Install failed: \(error.localizedDescription)\n"), stderr)
            exit(5)
        }
    }

    private static func uninstallHelper() {
        do {
            try HelperInstaller.uninstall()
            print(L("Yönetici yardımcısı kaldırıldı.", "Privileged helper removed."))
        } catch {
            fputs(L("Kaldırma başarısız: \(error.localizedDescription)\n", "Removal failed: \(error.localizedDescription)\n"), stderr)
            exit(5)
        }
    }

    static func printStatus() {
        guard let state = RuntimeStateStore.read() else {
            print("{\n  \"running\" : false\n}")
            return
        }
        var dictionary: [String: Any] = [:]
        dictionary["running"] = RuntimeStateStore.appIsRunning(pid: state.pid)
        dictionary["pid"] = state.pid
        dictionary["isOn"] = state.isOn
        dictionary["endDate"] = state.endDate.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
        dictionary["remaining"] = state.remaining ?? NSNull()
        dictionary["lidMode"] = state.lidMode
        dictionary["remoteBlankActive"] = state.remoteBlankActive
        dictionary["remoteLocked"] = state.remoteLocked
        dictionary["keepDisplayAwake"] = state.keepDisplayAwake
        dictionary["batteryPercent"] = state.batteryPercent ?? NSNull()
        dictionary["onBattery"] = state.onBattery ?? NSNull()
        dictionary["systemAssertion"] = state.systemAssertion
        dictionary["displayAssertion"] = state.displayAssertion
        if let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys]) {
            print(String(data: data, encoding: .utf8) ?? "{}")
        }
    }

    static func printDiagnostics() {
        print("Pusu \(version)")
        print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("")
        print("RUNTIME")
        print(RuntimeStateStore.readJSON() ?? "{\"running\": false}")
        print("")
        print("PMSET")
        print(Shell.run("/usr/bin/pmset", ["-g"]).stdout)
        print("")
        print("LID")
        let lid = LidStateReader.read()
        print("closed: \(lid.isClosed.map { $0 ? "yes" : "no" } ?? "unknown"), causes sleep: \(lid.causesSleep.map { $0 ? "yes" : "no" } ?? "unknown")")
        print("")
        print("HELPER")
        if let status = HelperClient.status() {
            print("running, version: \(status.version ?? "-") (bundled: \(HelperProtocol.version)), SleepDisabled: \(status.sleepDisabled), original: \(status.original.map { $0 ? "1" : "0" } ?? "-")")
        } else {
            print("not running / not installed")
        }
        print("daemon plist: \(HelperInstaller.daemonPlistExists)")
        print("")
        print("REMOTE ACCESS")
        print("screen sharing: \(RemoteController().screenSharingState().rawValue)")
    }
}

/// Çalışan ikili dosyanın ait olduğu `Pusu.app`. `pusu` bir sembolik bağ üzerinden
/// çağrıldığında da gerçek paketi bulur.
enum AppBundle {
    static var url: URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let executable = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS",
              contents.lastPathComponent == "Contents",
              bundle.pathExtension == "app"
        else { return nil }
        return bundle
    }

    /// Derleme sırasında `Info.plist`'e yazılan yardımcı özeti (`PusuHelperSHA256`).
    static var helperSHA256: String? {
        let bundle = url.flatMap(Bundle.init(url:)) ?? Bundle.main
        return bundle.object(forInfoDictionaryKey: "PusuHelperSHA256") as? String
    }

    static var helperURL: URL? {
        if let bundle = url {
            let helper = bundle.appendingPathComponent("Contents/Resources/pusu-helper")
            if FileManager.default.isExecutableFile(atPath: helper.path) { return helper }
        }
        return Bundle.main.url(forResource: "pusu-helper", withExtension: nil)
    }
}
