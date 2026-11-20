import Foundation
import Combine

public enum SessionStopReason: String, Codable, Equatable {
    case user
    case timer
    case battery
    case lidBattery
    case quit
    case error
    case interrupted

    public var label: String {
        switch self {
        case .user: return L("Kullanıcı kapattı", "Stopped by you")
        case .timer: return L("Süre doldu", "Time is up")
        case .battery: return L("Pil eşiği", "Battery threshold")
        case .lidBattery: return L("Kapak modu pil koruması", "Lid mode battery guard")
        case .quit: return L("Uygulama kapandı", "App quit")
        case .error: return L("Hata", "Error")
        case .interrupted: return L("Beklenmedik şekilde sonlandı", "Ended unexpectedly")
        }
    }
}

public enum PusuEvent {
    case started(PusuDuration)
    case stopped(SessionStopReason)
    case tick(TimeInterval?)
    case batteryUpdated(BatteryStatus?)
    case lidChanged(Bool)
    case remoteMode(active: Bool, locked: Bool, displaySlept: Bool)
    case message(title: String, body: String)
    case error(String)
}

public struct RuntimeState: Codable {
    public var pid: Int32
    public var isOn: Bool
    public var endDate: Date?
    public var remaining: TimeInterval?
    public var lidMode: Bool
    public var remoteBlankActive: Bool
    public var remoteLocked: Bool
    public var keepDisplayAwake: Bool
    public var keepSessionUnlocked: Bool
    public var batteryPercent: Int?
    public var onBattery: Bool?
    public var systemAssertion: Bool
    public var displayAssertion: Bool
    public var updatedAt: Date

    public init(
        pid: Int32,
        isOn: Bool,
        endDate: Date?,
        remaining: TimeInterval?,
        lidMode: Bool,
        remoteBlankActive: Bool,
        remoteLocked: Bool,
        keepDisplayAwake: Bool,
        keepSessionUnlocked: Bool,
        batteryPercent: Int?,
        onBattery: Bool?,
        systemAssertion: Bool,
        displayAssertion: Bool,
        updatedAt: Date
    ) {
        self.pid = pid
        self.isOn = isOn
        self.endDate = endDate
        self.remaining = remaining
        self.lidMode = lidMode
        self.remoteBlankActive = remoteBlankActive
        self.remoteLocked = remoteLocked
        self.keepDisplayAwake = keepDisplayAwake
        self.keepSessionUnlocked = keepSessionUnlocked
        self.batteryPercent = batteryPercent
        self.onBattery = onBattery
        self.systemAssertion = systemAssertion
        self.displayAssertion = displayAssertion
        self.updatedAt = updatedAt
    }
}

public enum RuntimePaths {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent("Pusu", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static var runtimeState: URL {
        supportDirectory.appendingPathComponent("runtime.json")
    }

    public static var history: URL {
        supportDirectory.appendingPathComponent("history.json")
    }

    public static var activeSession: URL {
        supportDirectory.appendingPathComponent("active-session.json")
    }
}

public enum RuntimeStateStore {
    public static func write(_ state: RuntimeState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: RuntimePaths.runtimeState, options: .atomic)
    }

    public static func read() -> RuntimeState? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: RuntimePaths.runtimeState) else { return nil }
        return try? decoder.decode(RuntimeState.self, from: data)
    }

    public static func readJSON() -> String? {
        guard let data = try? Data(contentsOf: RuntimePaths.runtimeState) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func appIsRunning(pid: Int32?) -> Bool {
        guard let pid, pid > 0 else { return false }
        return kill(pid, 0) == 0
    }
}

/// Saniyede bir değişen kalan süre. Ayrı tutulur ki `SessionController`'ı gözleyen
/// görünümler her saniye yeniden çizilmesin; geri sayım gösteren küçük görünümler bunu gözler.
public final class SessionClock: ObservableObject {
    @Published public internal(set) var remaining: TimeInterval?

    public init() {}
}

public final class SessionController: NSObject, ObservableObject {
    public let settings: SettingsStore
    public let assertions: PowerAsserting
    public let lid: LidControlling
    public let remote: RemoteControlling
    public let history: SessionHistoryStore
    private let readBattery: () -> BatteryStatus?
    private let writeRuntimeState: (RuntimeState) -> Void

    @Published public private(set) var isOn = false
    @Published public private(set) var endDate: Date?
    public let clock = SessionClock()
    /// Kalan süre (süresizse `nil`). Değişiklikler `clock` üzerinden yayınlanır.
    public var remaining: TimeInterval? { clock.remaining }
    @Published public private(set) var duration: PusuDuration?
    @Published public private(set) var battery: BatteryStatus?
    @Published public private(set) var lidMode = false
    @Published public private(set) var sleepDisabledActive = false
    @Published public private(set) var remoteBlankActive = false
    @Published public private(set) var remoteLocked = false
    @Published public private(set) var lastError: String?

    public var onEvent: ((PusuEvent) -> Void)?

    private var ticker: Timer?
    private var batteryTimer: Timer?
    private var userActivityTimer: Timer?
    private var tickCounter = 0

    /// - Parameters:
    ///   - batteryReader: pil durumunu okuyan fonksiyon (testlerde sahte değer).
    ///   - runtimeWriter: `runtime.json` yazıcısı; testler gerçek dosyaya dokunmamak için değiştirir.
    public init(
        settings: SettingsStore,
        assertions: PowerAsserting = PowerAssertions(),
        lid: LidControlling? = nil,
        remote: RemoteControlling = RemoteController(),
        history: SessionHistoryStore? = nil,
        batteryReader: @escaping () -> BatteryStatus? = BatteryReader.read,
        runtimeWriter: @escaping (RuntimeState) -> Void = RuntimeStateStore.write
    ) {
        self.settings = settings
        self.assertions = assertions
        self.lid = lid ?? LidController(settings: settings)
        self.remote = remote
        self.history = history ?? SessionHistoryStore()
        self.readBattery = batteryReader
        self.writeRuntimeState = runtimeWriter
        self.battery = batteryReader()
        super.init()

        self.settings.onChange = { [weak self] in
            self?.settingsChanged()
        }
        restoreLidState()
        writeRuntime()
    }

    // MARK: - Public control

    public func start(_ duration: PusuDuration) {
        lastError = nil
        let wasOn = isOn
        if !wasOn {
            let current = readBattery()
            battery = current
            if BatteryPolicy.shouldStop(
                battery: current,
                cutoffEnabled: settings.batteryCutoffEnabled,
                cutoffPercent: settings.batteryCutoffPercent
            ) {
                let message = L(
                    "Pil \(Localization.percent(current?.percent ?? 0)); pil eşiğinin altında olduğu için Pusu başlatılmadı.",
                    "Battery is at \(Localization.percent(current?.percent ?? 0)); Pusu did not start because it is below the battery threshold."
                )
                lastError = message
                onEvent?(.message(title: L("Pil azaldı", "Battery low"), body: message))
                return
            }
            history.begin(duration: duration)
            isOn = true
            startTimers()
        } else {
            history.updateRequestedDuration(duration)
        }
        if lidMode { history.markLidUsed() }
        self.duration = duration
        endDate = duration.endDate()
        clock.remaining = duration.remaining(until: endDate)
        applyAssertions()
        refreshBattery()
        writeRuntime()
        onEvent?(.started(duration))
    }

    public func stop(
        reason: SessionStopReason = .user,
        allowLidPrompt: Bool = true,
        wake: Bool = true,
        endedAt: Date? = nil
    ) {
        guard isOn else { return }

        let wasRemote = remoteBlankActive
        history.end(
            reason: reason,
            battery: battery,
            at: endedAt ?? Date()
        )
        isOn = false
        duration = nil
        endDate = nil
        clock.remaining = nil
        remoteBlankActive = false
        remoteLocked = false
        stopTimers()
        assertions.releaseAll()

        if wasRemote, wake {
            _ = remote.wakeDisplay()
        }

        if lidMode {
            do {
                try lid.setEnabled(false, allowPrompt: allowLidPrompt)
                lidMode = false
                sleepDisabledActive = lid.sleepDisabled() == true
                onEvent?(.lidChanged(false))
            } catch {
                lastError = error.localizedDescription
                onEvent?(.error(error.localizedDescription))
            }
        }

        writeRuntime()
        onEvent?(.stopped(reason))
    }

    /// - Parameters:
    ///   - allowLidPrompt: Kapatırken kapak modu için yönetici parolası sorulabilir mi?
    ///     Dışarıdan (CLI, URL, başka uygulama) gelen komutlarda `false` olmalıdır.
    ///   - maxDuration: Açarken varsayılan süreye uygulanacak üst sınır (URL'ler için).
    public func toggle(allowLidPrompt: Bool = true, maxDuration: TimeInterval? = nil) {
        if isOn {
            stop(reason: .user, allowLidPrompt: allowLidPrompt)
        } else {
            start(SessionController.capped(settings.defaultDuration, to: maxDuration))
        }
    }

    /// Süreyi (süresiz dahil) verilen üst sınıra indirir.
    public static func capped(_ duration: PusuDuration, to limit: TimeInterval?) -> PusuDuration {
        guard let limit else { return duration }
        guard let seconds = duration.seconds else { return PusuDuration(seconds: limit) }
        return PusuDuration(seconds: min(seconds, limit))
    }

    /// Aktif oturumun bitişini öne çeker; süresiz oturumu süreli hale getirir.
    public func extend(by seconds: TimeInterval) {
        guard isOn, seconds > 0 else { return }
        let base = endDate ?? Date()
        let newEnd = base.addingTimeInterval(seconds)
        let previousTotal = duration?.seconds
            ?? max(0, Date().timeIntervalSince(history.active?.startedAt ?? Date()))
        duration = PusuDuration(seconds: previousTotal + seconds)
        history.updateRequestedDuration(duration ?? .indefinite)
        endDate = newEnd
        clock.remaining = max(0, newEnd.timeIntervalSinceNow)
        writeRuntime()
        onEvent?(.started(duration ?? .indefinite))
    }

    public func clearError() {
        lastError = nil
    }

    /// Kapak modunu yönetici diyaloğunu ana thread'de bloklamadan açar/kapatır.
    public func setLidModeAsync(
        _ enabled: Bool,
        allowPrompt: Bool = true,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        if enabled, BatteryPolicy.shouldStop(
            battery: battery,
            cutoffEnabled: settings.batteryCutoffEnabled,
            cutoffPercent: settings.batteryCutoffPercent
        ) {
            completion(.failure(HelperError.commandFailed(L("Pil eşiğinin altında; kapak modu açılmadı.", "Battery is below the threshold; lid mode was not turned on."))))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.lid.setEnabled(enabled, allowPrompt: allowPrompt)
                let sleepDisabled = self.lid.sleepDisabled() == true
                DispatchQueue.main.async {
                    // Açarken SleepDisabled 1 olmalı. Kapatırken ise kullanıcının orijinal
                    // değeri 1 olabilir; geri yükleme başarılıysa bunu hata saymayız.
                    guard !enabled || sleepDisabled else {
                        completion(.failure(HelperError.commandFailed(L("SleepDisabled doğrulanamadı.", "Could not verify SleepDisabled."))))
                        return
                    }
                    if enabled {
                        if !self.isOn { self.start(.indefinite) }
                        guard self.isOn else {
                            try? self.lid.setEnabled(false, allowPrompt: false)
                            self.lastError = L("Pil eşiği nedeniyle oturum başlatılamadı.", "The session could not start because of the battery threshold.")
                            completion(.failure(HelperError.commandFailed(self.lastError!)))
                            return
                        }
                        self.lidMode = true
                        self.sleepDisabledActive = true
                        self.history.markLidUsed()
                        self.lastError = nil
                        self.writeRuntime()
                        self.onEvent?(.lidChanged(true))
                        if BatteryPolicy.shouldDisableLid(
                            battery: self.battery,
                            floorEnabled: self.settings.lidBatteryFloorEnabled,
                            floorPercent: self.settings.lidBatteryFloorPercent
                        ) {
                            let percent = Localization.percent(self.battery?.percent ?? 0)
                            let floor = Localization.percent(self.settings.lidBatteryFloorPercent)
                            self.onEvent?(.message(
                                title: L("Kapak modu pilde", "Lid mode on battery"),
                                body: L(
                                    "Pil \(percent). \(floor) altında otomatik kapanacak.",
                                    "Battery is at \(percent). Lid mode turns off automatically below \(floor)."
                                )
                            ))
                        }
                    } else {
                        self.lidMode = false
                        self.sleepDisabledActive = sleepDisabled
                        self.lastError = nil
                        self.writeRuntime()
                        self.onEvent?(.lidChanged(false))
                    }
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    completion(.failure(error))
                }
            }
        }
    }

    public func enterRemoteMode(lock: Bool) {
        if !isOn { start(.indefinite) }

        remoteBlankActive = true
        var locked = false
        if lock {
            locked = remote.lockScreen()
        }
        remoteLocked = locked
        applyAssertions()

        let slept = remote.sleepDisplay()
        history.markRemoteUsed()
        writeRuntime()
        onEvent?(.remoteMode(active: true, locked: locked, displaySlept: slept))
    }

    public func exitRemoteMode(wake: Bool = true) {
        if wake { _ = remote.wakeDisplay() }
        remoteBlankActive = false
        remoteLocked = false
        if isOn { applyAssertions() }
        writeRuntime()
        onEvent?(.remoteMode(active: false, locked: false, displaySlept: false))
    }

    public func shutdown() {
        if isOn {
            history.end(
                reason: .quit,
                battery: battery
            )
        }
        stopTimers()
        assertions.releaseAll()
        if lidMode, lid.helperResponding {
            if (try? lid.setEnabled(false, allowPrompt: false)) != nil {
                lidMode = false
            }
            sleepDisabledActive = lid.sleepDisabled() == true
        }
        remoteBlankActive = false
        remoteLocked = false
        isOn = false
        duration = nil
        endDate = nil
        clock.remaining = nil
        writeRuntime()
    }

    public func refreshBattery() {
        let status = readBattery()
        battery = status
        sleepDisabledActive = lid.sleepDisabled() == true
        onEvent?(.batteryUpdated(status))

        // Kapak modu açık sanıyoruz ama SleepDisabled dışarıdan geri alınmış (ör. yardımcı
        // kendini kaldırdı ya da kullanıcı pmset çalıştırdı): durumu düzelt ve haber ver.
        if lidMode, !sleepDisabledActive {
            lidMode = false
            writeRuntime()
            onEvent?(.lidChanged(false))
            onEvent?(.message(
                title: L("Kapak modu kapandı", "Lid mode turned off"),
                body: L(
                    "Uyku ayarı Pusu dışında geri alındı; kapak kapanınca Mac uyuyabilir.",
                    "The sleep setting was restored outside Pusu; the Mac may sleep when the lid closes."
                )
            ))
        }

        guard isOn else { return }

        if BatteryPolicy.shouldStop(
            battery: status,
            cutoffEnabled: settings.batteryCutoffEnabled,
            cutoffPercent: settings.batteryCutoffPercent
        ) {
            stop(reason: .battery, allowLidPrompt: false)
            let percent = Localization.percent(status?.percent ?? 0)
            onEvent?(.message(
                title: L("Pil azaldı", "Battery low"),
                body: L("Pil \(percent). Pusu otomatik kapatıldı.", "Battery is at \(percent). Pusu turned itself off.")
            ))
            return
        }

        if lidMode, BatteryPolicy.shouldDisableLid(
            battery: status,
            floorEnabled: settings.lidBatteryFloorEnabled,
            floorPercent: settings.lidBatteryFloorPercent
        ) {
            do {
                try lid.setEnabled(false, allowPrompt: false)
                lidMode = false
                onEvent?(.lidChanged(false))
                let percent = Localization.percent(status?.percent ?? 0)
                onEvent?(.message(
                    title: L("Kapak modu kapatıldı", "Lid mode turned off"),
                    body: L("Pil \(percent). Pil koruması devreye girdi.", "Battery is at \(percent). The battery guard kicked in.")
                ))
                stop(reason: .lidBattery, allowLidPrompt: false)
            } catch {
                lastError = error.localizedDescription
                onEvent?(.error(L("Kapak modu kapatılamadı: \(error.localizedDescription)", "Could not turn off lid mode: \(error.localizedDescription)")))
            }
        }
    }

    public func refreshLidState() {
        sleepDisabledActive = lid.sleepDisabled() == true
        lidMode = sleepDisabledActive && (lid.helperAvailable || lid.usesFallback)
        if isOn, lidMode { history.markLidUsed() }
    }

    public func diagnostics(appVersion: String) -> String {
        Diagnostics.collect(settings: settings, session: self, appVersion: appVersion)
    }

    // MARK: - Assertions and timers

    private func applyAssertions() {
        guard isOn else { return }
        _ = assertions.acquire(
            system: true,
            display: settings.keepDisplayAwake,
            reason: "Pusu keeps the system up"
        )
        // Karartma sırasında "kullanıcı etkin" bildirimi gönderilmez: macOS bunu tuşa basılmış
        // gibi algılar ve kapatılan ekranı (ve klavye ışığını) yeniden yakar.
        if settings.keepSessionUnlocked, !remoteBlankActive {
            startUserActivityTimer()
        } else {
            stopUserActivityTimer()
            assertions.releaseUserActivity()
        }
    }

    private func startTimers() {
        if ticker == nil {
            let timer = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
        if batteryTimer == nil {
            let timer = Timer(timeInterval: 20, target: self, selector: #selector(batteryTick), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            batteryTimer = timer
        }
    }

    private func stopTimers() {
        ticker?.invalidate()
        ticker = nil
        batteryTimer?.invalidate()
        batteryTimer = nil
        stopUserActivityTimer()
    }

    private func startUserActivityTimer() {
        guard userActivityTimer == nil else { return }
        _ = assertions.declareUserActivity()
        let timer = Timer(timeInterval: 30, target: self, selector: #selector(userActivityTick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        userActivityTimer = timer
    }

    private func stopUserActivityTimer() {
        userActivityTimer?.invalidate()
        userActivityTimer = nil
    }

    @objc private func tick() {
        processTick()
    }

    /// Bir saniyelik zamanlayıcı adımı. Testler zamanı ilerletmek için doğrudan çağırır.
    public func processTick(now: Date = Date()) {
        guard isOn else { return }
        if let endDate {
            let value = max(0, endDate.timeIntervalSince(now))
            clock.remaining = value
            if value <= 0 {
                stop(reason: .timer, endedAt: endDate)
                onEvent?(.message(title: L("Süre doldu", "Time is up"), body: L("Pusu kapandı.", "Pusu turned off.")))
                return
            }
        }
        tickCounter += 1
        onEvent?(.tick(remaining))
        if tickCounter % 60 == 0 { history.heartbeat(at: now) }
        if tickCounter % 5 == 0 { writeRuntime() }
    }

    @objc private func batteryTick() {
        refreshBattery()
    }

    @objc private func userActivityTick() {
        guard isOn, settings.keepSessionUnlocked else { return }
        if remoteLocked || remoteBlankActive { return }
        _ = assertions.declareUserActivity()
    }

    private func settingsChanged() {
        guard isOn else {
            writeRuntime()
            return
        }
        applyAssertions()
        writeRuntime()
    }

    private func restoreLidState() {
        sleepDisabledActive = lid.sleepDisabled() == true
        if lid.usesFallback {
            lidMode = sleepDisabledActive
            return
        }
        if let status = lid.helperStatus(), status.sleepDisabled, status.original != nil {
            lidMode = true
        } else {
            lidMode = false
        }
    }

    // MARK: - Runtime state

    private func writeRuntime() {
        let state = RuntimeState(
            pid: getpid(),
            isOn: isOn,
            endDate: endDate,
            remaining: remaining,
            lidMode: lidMode,
            remoteBlankActive: remoteBlankActive,
            remoteLocked: remoteLocked,
            keepDisplayAwake: settings.keepDisplayAwake,
            keepSessionUnlocked: settings.keepSessionUnlocked,
            batteryPercent: battery?.percent,
            onBattery: battery?.isOnBattery,
            systemAssertion: assertions.isSystemHeld,
            displayAssertion: assertions.isDisplayHeld,
            updatedAt: Date()
        )
        writeRuntimeState(state)
    }
}

/// Hata bildirimleri için teknik rapor. Arayüz dilinden bağımsız olarak İngilizce üretilir,
/// böylece GitHub issue'larında herkes okuyabilir.
public enum Diagnostics {
    public static func collect(settings: SettingsStore, session: SessionController, appVersion: String) -> String {
        func flag(_ value: Bool?) -> String {
            value.map { $0 ? "yes" : "no" } ?? "unknown"
        }
        func percent(_ enabled: Bool, _ value: Int) -> String {
            enabled ? "\(value)%" : "off"
        }

        var lines: [String] = []
        lines.append("Pusu \(appVersion)")
        lines.append("Time: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("PID: \(getpid())")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("UI language: \(Localization.resolved.rawValue) (preference: \(Localization.preference.rawValue))")
        lines.append("")

        lines.append("STATE")
        lines.append("  on: \(session.isOn)")
        lines.append("  remaining: \(session.remaining.map { TimeText.countdown($0) } ?? "-")")
        lines.append("  lid mode: \(session.lidMode)")
        lines.append("  VNC blackout: \(session.remoteBlankActive) (locked: \(session.remoteLocked))")
        lines.append("  system assertion: \(session.assertions.isSystemHeld)")
        lines.append("  display assertion: \(session.assertions.isDisplayHeld)")
        lines.append("  user activity assertion: \(session.assertions.isUserActivityHeld)")
        lines.append("")

        lines.append("SETTINGS")
        lines.append("  keep display awake: \(settings.keepDisplayAwake)")
        lines.append("  keep session unlocked: \(settings.keepSessionUnlocked)")
        lines.append("  battery cutoff: \(percent(settings.batteryCutoffEnabled, settings.batteryCutoffPercent))")
        lines.append("  lid battery guard: \(percent(settings.lidBatteryFloorEnabled, settings.lidBatteryFloorPercent))")
        lines.append("  hotkey: \(settings.hotkeyPreset.rawValue)")
        lines.append("  launch at login: \(settings.launchAtLogin)")
        lines.append("")

        if let battery = session.battery {
            lines.append("BATTERY")
            lines.append("  present: \(battery.isPresent), percent: \(battery.percent), on battery: \(battery.isOnBattery), charging: \(battery.isCharging)")
            lines.append("  minutes remaining: \(battery.minutesRemaining.map(String.init) ?? "-")")
            lines.append("")
        }

        let lidSnapshot = LidStateReader.read()
        lines.append("LID")
        lines.append("  closed: \(flag(lidSnapshot.isClosed))")
        lines.append("  causes sleep: \(flag(lidSnapshot.causesSleep))")
        lines.append("  SleepDisabled: \(session.lid.sleepDisabled().map { $0 ? "1" : "0" } ?? "unknown")")
        lines.append("  fallback (no helper): \(session.lid.usesFallback)")
        lines.append("")

        lines.append("HELPER")
        if let status = session.lid.helperStatus() {
            lines.append("  running: \(status.ok), version: \(status.version ?? "-") (bundled: \(HelperProtocol.version))")
            lines.append("  SleepDisabled: \(status.sleepDisabled), original: \(status.original.map { $0 ? "1" : "0" } ?? "-")")
            lines.append("  watching: \(status.appBundle ?? "-") (this app: \(HelperProtocol.currentAppBundlePath ?? "-"))")
        } else {
            lines.append("  not running / not installed")
        }
        lines.append("  daemon plist: \(HelperInstaller.daemonPlistExists)")
        lines.append("")

        let sharing = session.remote.screenSharingState()
        lines.append("REMOTE ACCESS")
        lines.append("  screen sharing: \(sharing.rawValue)")
        lines.append("  ARDAgent: \(session.remote.remoteManagementRunning())")
        lines.append("")

        let pmset = Shell.run("/usr/bin/pmset", ["-g"])
        lines.append("PMSET")
        for line in pmset.stdout.split(separator: "\n") {
            let text = String(line)
            if text.contains("SleepDisabled") || text.hasPrefix(" sleep") ||
                text.hasPrefix(" displaysleep") || text.contains("hibernatemode") ||
                text.contains("lowpowermode") || text.contains("powernap") {
                lines.append("  \(text.trimmingCharacters(in: .whitespaces))")
            }
        }
        lines.append("")

        let assertions = Shell.run("/usr/bin/pmset", ["-g", "assertions"])
        lines.append("ASSERTIONS")
        for line in assertions.stdout.split(separator: "\n") {
            let text = String(line)
            if text.contains("Pusu") || text.contains("PreventUserIdleSystemSleep") ||
                text.contains("PreventUserIdleDisplaySleep") || text.contains("UserIsActive") ||
                text.contains("InternalPreventDisplaySleep") {
                lines.append("  \(text.trimmingCharacters(in: .whitespaces))")
            }
        }
        lines.append("")

        lines.append("HELPER LOG")
        if let log = try? String(contentsOfFile: HelperProtocol.logPath, encoding: .utf8) {
            for line in log.split(separator: "\n").suffix(12) {
                lines.append("  \(line)")
            }
        } else {
            lines.append("  unavailable")
        }

        return lines.joined(separator: "\n")
    }
}
