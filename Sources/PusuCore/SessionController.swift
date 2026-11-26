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
    case sleep

    public var label: String {
        switch self {
        case .user: return L("Kullanıcı kapattı", "Stopped by you")
        case .timer: return L("Süre doldu", "Time is up")
        case .battery: return L("Pil eşiği", "Battery threshold")
        case .lidBattery: return L("Kapak modu pil koruması", "Lid mode battery guard")
        case .quit: return L("Uygulama kapandı", "App quit")
        case .error: return L("Hata", "Error")
        case .interrupted: return L("Beklenmedik şekilde sonlandı", "Ended unexpectedly")
        case .sleep: return L("Mac uyutuldu", "Mac was put to sleep")
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

    public static var events: URL {
        supportDirectory.appendingPathComponent("events.log")
    }

    /// Uygulamanın en son aldığı CLI komutunun kimliği (CLI teslimi doğrulamak için okur).
    public static var commandAck: URL {
        supportDirectory.appendingPathComponent("command-ack")
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
    public let activity: ActivityPosting
    public let history: SessionHistoryStore
    /// Kısa süreli olay günlüğü (`nil`: kayıt tutulmaz; testler sahtesini verir).
    public let events: EventRecording?
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
    /// Uzak erişim modunda ekran açık ama karartılmış mı (parlaklık 0, siyah görüntü)?
    @Published public private(set) var remotePanelDark = false
    /// Uzak erişim modunda (kapak kapalıyken) sanal ekran açık mı?
    @Published public private(set) var remoteVirtualDisplay = false
    /// Uzak erişim modunda ekran bağlantı beklerken uyutuldu mu?
    @Published public private(set) var remoteDisplaySlept = false
    public var remoteClientConnected: Bool { remoteClients?.isConnected == true }
    public let remoteClients: RemoteClientMonitoring?
    private let lidClosedReader: () -> Bool?
    private var lastLidClosed: Bool?
    private var remoteLockRequested = false
    private var darkSince: Date?
    private var localInputBaseline = Date.distantPast
    /// Modu başlattıktan sonraki bu süre içindeki dokunuşlar sayılmaz (menüden tıklama vb.).
    static let localInputGrace: TimeInterval = 3
    private var darkPending = false
    private var darkFailureLogged = false
    private var lastViewedAt: Date?
    private var viewedSinceWake = false
    /// Tern ayrıldıktan sonra ekranın uyutulacağı an (hemen yeniden bağlanırsa iptal edilir).
    private var pendingIdleAt: Date?
    /// Son bağlantı anları: art arda bağlanıp kopan istemciyi tanımak için.
    private var recentAttaches: [Date] = []
    /// Art arda bağlanıp kopan Tern'in bağlantı olayları bu ana kadar yok sayılır.
    private var clientEventsIgnoredUntil: Date?
    @Published public private(set) var lastError: String?

    public var onEvent: ((PusuEvent) -> Void)?

    private var ticker: Timer?
    private var batteryTimer: Timer?
    private var userActivityTimer: Timer?
    private var activityNudgeLogged = false
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
        events: EventRecording? = nil,
        remoteClients: RemoteClientMonitoring? = nil,
        activity: ActivityPosting = SyntheticActivity(),
        lidClosedReader: @escaping () -> Bool? = { LidStateReader.read().isClosed },
        batteryReader: @escaping () -> BatteryStatus? = BatteryReader.read,
        runtimeWriter: @escaping (RuntimeState) -> Void = RuntimeStateStore.write
    ) {
        self.settings = settings
        self.assertions = assertions
        self.lid = lid ?? LidController(settings: settings)
        self.remote = remote
        self.activity = activity
        self.history = history ?? SessionHistoryStore()
        self.events = events
        self.remoteClients = remoteClients
        self.lidClosedReader = lidClosedReader
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
                log("Session not started: battery \(current?.percent ?? 0)% is below the threshold")
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
        log(wasOn ? "Duration changed: \(Self.logLabel(duration))" : "Session on: \(Self.logLabel(duration))")
        emit(.started(duration))
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
        if wasRemote { teardownRemoteMode() }
        stopTimers()
        assertions.releaseAll()

        if wasRemote {
            let woke = wake ? remote.wakeDisplay() : false
            log(wake ? "Remote access mode off (display wake: \(woke ? "ok" : "failed"))" : "Remote access mode off")
        }

        if lidMode {
            do {
                try lid.setEnabled(false, allowPrompt: allowLidPrompt)
                lidMode = false
                sleepDisabledActive = lid.sleepDisabled() == true
                emit(.lidChanged(false))
            } catch {
                lastError = error.localizedDescription
                emit(.error(error.localizedDescription))
            }
        }

        writeRuntime()
        log("Session off (reason: \(reason.rawValue))")
        emit(.stopped(reason))
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
        log("Session extended by \(Self.logLabel(PusuDuration(seconds: seconds))), now \(Self.logLabel(duration ?? .indefinite)) in total")
        emit(.started(duration ?? .indefinite))
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
                        self.emit(.lidChanged(true))
                        if BatteryPolicy.shouldDisableLid(
                            battery: self.battery,
                            floorEnabled: self.settings.lidBatteryFloorEnabled,
                            floorPercent: self.settings.lidBatteryFloorPercent
                        ) {
                            let percent = Localization.percent(self.battery?.percent ?? 0)
                            let floor = Localization.percent(self.settings.lidBatteryFloorPercent)
                            self.emit(.message(
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
                        self.emit(.lidChanged(false))
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

    /// Uzak erişim modu.
    ///
    /// - Kapak açık, kimse izlemiyor: oturum kilitlenir, ekran uyur (en az pil).
    /// - Tern bağlanınca ekran uyanır ama panel ve klavye ışığı karanlık kalır. 30 saniye içinde
    ///   kimse ekranı izlemezse (yalnızca terminal) ekran yeniden uyur.
    /// - Ekran bir kez izlendiyse, bağlantı sürdükçe karanlık ve açık kalır (sekme değiştirip
    ///   dönünce ekran hazırdır). Bağlantı kapanınca ya da 10 dakika izlenmezse kilitlenip uyur.
    /// - Ekran uyurken biri izlemeye başlarsa (Apple Ekran Paylaşımı ekranı kendisi uyandırır)
    ///   panel hemen karartılır.
    /// - "Ekranı hiç uyutma" ayarı açıksa ekran hep açık ama karanlıktır (diğer uygulamalar için).
    /// - Kapak kapalı ve kapak modu açıksa dahili ekran zaten kapalıdır; uzak bağlantı görebilsin
    ///   diye sanal bir ekran açılır.
    public func enterRemoteMode(lock: Bool) {
        if !isOn { start(.indefinite) }

        remoteBlankActive = true
        remoteLockRequested = lock
        remote.rememberPanelLevels()
        // Modu başlatan tıklama "Mac başında biri var" sayılmasın: bundan sonrası sayılır.
        localInputBaseline = max(remote.lastLocalInputDate() ?? .distantPast, Date().addingTimeInterval(Self.localInputGrace))
        let locked = lock ? remote.lockScreen() : false
        remoteLocked = locked
        log("Remote access mode on (lock requested: \(Self.yesNo(lock)), locked: \(Self.yesNo(locked)))")

        remoteClients?.onClientEvent = { [weak self] attached in
            self?.remoteClientEvent(attached: attached)
        }
        remoteClients?.onScreenRequest = { [weak self] in
            self?.remoteScreenRequested()
        }
        remoteClients?.start()

        lastLidClosed = lidClosedReader()
        if usesVirtualDisplay {
            updateVirtualDisplay()
        } else if remoteKeepsDisplayAwake || remote.screenIsBeingWatched() {
            // Ekranı şu an izleyen biri var (ör. modu uzaktan başlattı): uyutma, karart.
            if remote.screenIsBeingWatched() { lastViewedAt = Date(); viewedSinceWake = true }
            wakeDark(reason: remoteKeepsDisplayAwake ? "Display kept on (lid mode or setting)" : "Screen is being viewed")
        } else {
            goIdle(relock: false)
        }
        history.markRemoteUsed()
        writeRuntime()
        emit(.remoteMode(active: true, locked: locked, displaySlept: remoteDisplaySlept || remotePanelDark || remoteVirtualDisplay))
    }

    public func exitRemoteMode(wake: Bool = true) {
        guard remoteBlankActive else { return }
        teardownRemoteMode()
        let woke = wake ? remote.wakeDisplay() : false
        log(wake ? "Remote access mode off (display wake: \(woke ? "ok" : "failed"))" : "Remote access mode off")
        if isOn { applyAssertions() }
        writeRuntime()
        emit(.remoteMode(active: false, locked: false, displaySlept: false))
    }

    /// Mac'in kendi trackpad'i/klavyesi kullanıldı (uzaktan gelen değil): Mac başında biri var.
    public func localInputDetected() {
        guard remoteBlankActive else { return }
        log("Input from this Mac's own trackpad or keyboard; leaving remote access mode")
        exitRemoteMode(wake: true)
    }

    /// Bağlantı gelince karartılmış ekranın açık kalacağı süre (kimse izlemezse).
    public static let remoteUnviewedTimeout: TimeInterval = 30
    /// Ekran bir kez izlendikten sonra, izleme olmadan açık kalacağı en uzun süre.
    public static let remoteViewedTimeout: TimeInterval = 10 * 60

    /// Ekran hiç uyutulmaz, karanlık tutulur: ayar açıksa ya da kapak modu açıksa. Kapak modu
    /// açıkken kapak, uyanık bir ekranla kapanmalıdır: ancak o zaman macOS dahili ekranı devreden
    /// çıkarır ve kilit ekranı (parola kutusu) sanal ekrana geçer. Uyuyan ekranla kapanırsa kilit
    /// ekranı görünmeyen dahili ekranda kalır.
    private var remoteKeepsDisplayAwake: Bool {
        settings.remoteKeepsDisplayOn || lidMode || sleepDisabledActive
    }

    private var usesVirtualDisplay: Bool {
        lastLidClosed == true && (lidMode || sleepDisabledActive)
    }

    /// Ekranı uyandırır ama panel ve klavye ışığını karanlık tutar.
    private func wakeDark(reason: String) {
        guard remoteBlankActive else { return }
        darkSince = Date()
        guard !remotePanelDark else { return }
        // Önce karart (uyuyan ekranın parlaklığı da ayarlanabilir), sonra uyandır. Renk eğrisi
        // ancak ekran açıldıktan sonra uygulanabildiği için kısa aralıklarla yeniden denenir.
        darkFailureLogged = false
        let wasAsleep = remoteDisplaySlept
        var dark = remote.darkenPanel()
        if wasAsleep { _ = remote.wakeDisplay() }
        remoteDisplaySlept = false
        dark = remote.darkenPanel() || dark
        darkPending = !dark
        remotePanelDark = dark
        if dark {
            log("\(reason): display on, panel and keyboard dark")
        } else {
            log("\(reason): waking the display dark")
            retryDarken(attempt: 1)
        }
        applyAssertions()
        writeRuntime()
    }

    /// Uyanan ekran aktif olunca karartmayı tamamla (uyanma ~0,5 sn sürer).
    private func retryDarken(attempt: Int) {
        // Ekran açılır açılmaz karartmak için sık dene (25 ms, en fazla ~3 sn).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            guard let self, self.remoteBlankActive, self.darkPending, self.darkSince != nil else { return }
            self.completePendingDarken()
            if self.darkPending, attempt < 120 { self.retryDarken(attempt: attempt + 1) }
        }
    }

    private func completePendingDarken() {
        guard darkPending else { return }
        if remote.darkenPanel() {
            darkPending = false
            remotePanelDark = true
            log("Panel and keyboard dark")
            applyAssertions()
            writeRuntime()
        }
    }

    /// Kimse izlemiyor: parlaklığı geri al, gerekirse yeniden kilitle ve ekranı uyut.
    private func goIdle(relock: Bool) {
        restorePanelIfNeeded()
        // Karartma tamamlanamadıysa da kaydedilen parlaklık geri yüklenir.
        if darkPending { remote.restorePanel() }
        darkPending = false
        viewedSinceWake = false
        darkSince = nil
        // Uzaktaki kişi kilitlemeyi unutmuş olabilir.
        if relock, remoteLockRequested, !remote.isScreenLocked() {
            remoteLocked = remote.lockScreen()
        }
        applyAssertions()
        remoteDisplaySlept = remote.sleepDisplay()
        log(remoteDisplaySlept ? "Display asleep until a remote connection" : "Display sleep failed")
        writeRuntime()
    }

    /// Ayrılmadan sonra ekranı uyutmadan önce beklenen süre: Tern yeniden başlarken ya da ağ
    /// değişirken bağlantı bir an kopup geri gelir; ekran her seferinde uyuyup kilitlenmesin.
    public static let remoteDetachGrace: TimeInterval = 5
    /// Bu süre içinde bu kadar yeni bağlantı gelirse istemci "art arda bağlanıp kopuyor" sayılır
    /// (ör. Tern güncellenince eski uzak sunucu saniyede bir bağlanıp atılıyor).
    public static let remoteFlapWindow: TimeInterval = 20
    public static let remoteFlapLimit = 4
    /// Art arda bağlanıp kopan istemcinin olaylarının yok sayılacağı süre.
    public static let remoteFlapIgnore: TimeInterval = 5 * 60

    private func remoteClientEvent(attached: Bool, now: Date = Date()) {
        guard remoteBlankActive else { return }
        if let until = clientEventsIgnoredUntil, now < until { return }
        clientEventsIgnoredUntil = nil
        if attached {
            recentAttaches = recentAttaches.filter { now.timeIntervalSince($0) < Self.remoteFlapWindow } + [now]
            if recentAttaches.count >= Self.remoteFlapLimit {
                // Ekranı her olayda uyutup uyandırmak hem ekranı yanıp söndürür hem de ana
                // kuyruğu tıkar (Mac başındaki kişinin dokunuşu bile işlenemez). Bir süre dinleme.
                recentAttaches = []
                pendingIdleAt = nil
                clientEventsIgnoredUntil = now.addingTimeInterval(Self.remoteFlapIgnore)
                log("Tern keeps reconnecting; ignoring its connections for 5 minutes")
                return
            }
        }
        log(attached ? "Remote client connected (Tern)" : "Remote client disconnected (Tern)")
        guard !usesVirtualDisplay, !remoteKeepsDisplayAwake else { return }
        if attached {
            pendingIdleAt = nil
            // Yeni bağlantı: ekranı karanlık uyandır, kimse izlemezse 30 sn sonra yeniden uyut.
            if darkSince == nil { viewedSinceWake = remote.screenIsBeingWatched() }
            wakeDark(reason: "Remote client connected")
        } else if darkSince != nil {
            // Hemen uyutma: bağlantı birkaç saniye içinde geri gelebilir.
            pendingIdleAt = now.addingTimeInterval(Self.remoteDetachGrace)
        }
    }

    /// Testler için: Tern bağlantı olayını belirli bir anda işle.
    public func handleRemoteClientEvent(attached: Bool, now: Date) {
        remoteClientEvent(attached: attached, now: now)
    }

    /// Tern ekranı paylaşmak istedi. Bağlantı zaten açıkken (ör. terminal sekmesi) Screen
    /// açılınca yeni bağlantı satırı düşmez; uyuyan ekranı karanlık uyandır ki Tern bir sonraki
    /// denemede ekranı bulsun. Ekran zaten karanlık açıksa 30 sn'lik süre baştan başlar.
    public func remoteScreenRequested() {
        guard remoteBlankActive, !usesVirtualDisplay, !remoteKeepsDisplayAwake else { return }
        if darkSince == nil {
            log("Tern asked to share the screen")
            viewedSinceWake = remote.screenIsBeingWatched()
            wakeDark(reason: "Screen requested")
        } else {
            darkSince = Date()
        }
    }

    /// Her saniye: karartmayı koru, izlenmeyi ve kapağı takip et.
    private func remoteTick(now: Date) {
        if let input = remote.lastLocalInputDate(), input > localInputBaseline {
            localInputDetected()
            return
        }
        if tickCounter % 2 == 0 { checkLidForRemoteMode() }
        // Kapak açıldıysa mod az önce bitmiş olabilir.
        guard remoteBlankActive, !usesVirtualDisplay else { return }
        if remotePanelDark { remote.maintainDarkPanel() }
        if darkPending {
            completePendingDarken()
            if darkPending, let since = darkSince, now.timeIntervalSince(since) >= 5, !darkFailureLogged {
                darkFailureLogged = true
                log("Display could not be darkened")
            }
        }
        if remoteKeepsDisplayAwake {
            // Kapak modu sonradan açıldıysa uyuyan ekranı karanlık uyandır.
            if darkSince == nil { wakeDark(reason: "Lid mode is on") }
            return
        }

        if let idleAt = pendingIdleAt, now >= idleAt {
            pendingIdleAt = nil
            if darkSince != nil, remoteClients?.isConnected != true, !remote.screenIsBeingWatched() {
                goIdle(relock: true)
                return
            }
        }

        if remote.screenIsBeingWatched() {
            lastViewedAt = now
            if darkSince == nil {
                // Ekran uyurken biri izlemeye başladı (ör. Apple Ekran Paylaşımı uyandırdı).
                viewedSinceWake = true
                wakeDark(reason: "Screen is being viewed")
            } else if !viewedSinceWake {
                viewedSinceWake = true
                log("Screen is being viewed")
            }
            return
        }

        guard let darkSince else { return }
        let since = max(darkSince, lastViewedAt ?? .distantPast)
        let limit = viewedSinceWake ? Self.remoteViewedTimeout : Self.remoteUnviewedTimeout
        if now.timeIntervalSince(since) >= limit {
            log(viewedSinceWake ? "Screen not viewed for 10 minutes" : "Nobody viewed the screen")
            goIdle(relock: true)
        }
    }

    /// Kapak kapalıyken sanal ekranı aç, açılınca kaldır.
    private func updateVirtualDisplay() {
        if usesVirtualDisplay {
            // Kapak kapalı: dahili ekran devre dışı. Uzak bağlantı için sanal ekran.
            restorePanelIfNeeded()
            if darkPending { remote.restorePanel() }
            darkPending = false
            darkSince = nil
            viewedSinceWake = false
            if !remote.virtualDisplayActive {
                let shown = remote.showVirtualDisplay()
                log(shown ? "Lid closed: virtual display on" : "Lid closed: virtual display could not be created")
            }
            remoteVirtualDisplay = remote.virtualDisplayActive
            remoteDisplaySlept = false
        } else {
            if remote.virtualDisplayActive {
                remote.hideVirtualDisplay()
                log("Virtual display off")
            }
            remoteVirtualDisplay = false
        }
        applyAssertions()
    }

    /// Kapak açıldı/kapandı mı? İki saniyede bir bakılır.
    private func checkLidForRemoteMode() {
        let closed = lidClosedReader()
        guard closed != lastLidClosed else { return }
        let wasClosed = lastLidClosed == true
        lastLidClosed = closed
        if wasClosed, closed == false {
            // Kapağı yalnızca Mac'in başındaki biri açabilir: modu bitir, ekranı geri ver.
            log("Lid opened on this Mac; leaving remote access mode")
            exitRemoteMode(wake: true)
            return
        }
        log(closed == true ? "Lid closed" : "Lid opened")
        updateVirtualDisplay()
        writeRuntime()
    }

    /// Uzak erişim modunun bütün yan etkilerini geri alır.
    private func teardownRemoteMode() {
        remoteClients?.stop()
        remoteClients?.onClientEvent = nil
        remoteClients?.onScreenRequest = nil
        if darkPending { remote.restorePanel() }
        darkPending = false
        darkFailureLogged = false
        darkSince = nil
        lastViewedAt = nil
        viewedSinceWake = false
        pendingIdleAt = nil
        recentAttaches = []
        clientEventsIgnoredUntil = nil
        restorePanelIfNeeded()
        if remote.virtualDisplayActive {
            remote.hideVirtualDisplay()
            log("Virtual display off")
        }
        remote.forgetPanelLevels()
        remoteVirtualDisplay = false
        remoteDisplaySlept = false
        remoteBlankActive = false
        remoteLocked = false
        remoteLockRequested = false
    }

    public func shutdown() {
        if remoteBlankActive { teardownRemoteMode() }
        if isOn {
            log("Session off (reason: quit)")
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
        emit(.batteryUpdated(status))

        // Kapak modu açık sanıyoruz ama SleepDisabled dışarıdan geri alınmış (ör. yardımcı
        // kendini kaldırdı ya da kullanıcı pmset çalıştırdı): durumu düzelt ve haber ver.
        if lidMode, !sleepDisabledActive {
            lidMode = false
            writeRuntime()
            emit(.lidChanged(false))
            emit(.message(
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
            emit(.message(
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
                emit(.lidChanged(false))
                let percent = Localization.percent(status?.percent ?? 0)
                emit(.message(
                    title: L("Kapak modu kapatıldı", "Lid mode turned off"),
                    body: L("Pil \(percent). Pil koruması devreye girdi.", "Battery is at \(percent). The battery guard kicked in.")
                ))
                stop(reason: .lidBattery, allowLidPrompt: false)
            } catch {
                lastError = error.localizedDescription
                emit(.error(L("Kapak modu kapatılamadı: \(error.localizedDescription)", "Could not turn off lid mode: \(error.localizedDescription)")))
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

    private func restorePanelIfNeeded() {
        guard remotePanelDark else { return }
        remote.restorePanel()
        remotePanelDark = false
        log("Display brightness and keyboard light restored")
    }

    // MARK: - Events

    private func emit(_ event: PusuEvent) {
        if let text = Self.logText(for: event) { log(text) }
        onEvent?(event)
    }

    private func log(_ message: String) {
        events?.record(message)
    }

    /// Olayın günlük satırı. Oturum ve uzak erişim olayları, daha ayrıntılı oldukları için
    /// gerçekleştikleri yerde yazılır.
    static func logText(for event: PusuEvent) -> String? {
        switch event {
        case .lidChanged(let enabled):
            return "Lid mode \(enabled ? "on" : "off")"
        case .message(let title, let body):
            return "Notice: \(title): \(body)"
        case .error(let message):
            return "Error: \(message)"
        case .started, .stopped, .remoteMode, .tick, .batteryUpdated:
            return nil
        }
    }

    public static func logLabel(_ duration: PusuDuration) -> String {
        guard let seconds = duration.seconds else { return "indefinite" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let hours = total / 3600, minutes = (total % 3600) / 60
        if hours == 0 { return "\(minutes)m" }
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    // MARK: - Assertions and timers

    private func applyAssertions() {
        guard isOn else { return }
        // Karartılmış (uyutulmamış) ekranda uzak bağlantı ekranı görebilsin diye ekran,
        // "ekranı uyanık tut" ayarı kapalı olsa da açık tutulur.
        _ = assertions.acquire(
            system: true,
            display: remoteBlankActive
                ? (darkSince != nil || remotePanelDark || remoteVirtualDisplay)
                : settings.keepDisplayAwake,
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
                emit(.message(title: L("Süre doldu", "Time is up"), body: L("Pusu kapandı.", "Pusu turned off.")))
                return
            }
        }
        tickCounter += 1
        emit(.tick(remaining))
        if tickCounter % 60 == 0 { history.heartbeat(at: now) }
        if tickCounter % 5 == 0 { writeRuntime() }
        if tickCounter % AppActivityPolicy.checkInterval == 0 { appActivityTick() }
        if remoteBlankActive { remoteTick(now: now) }
    }

    @objc private func batteryTick() {
        refreshBattery()
    }

    /// "Uygulamaları aktif tut": kullanıcı bir süredir dokunmadıysa görünmez bir fare olayı
    /// gönderir. Uzak erişim modunda gönderilmez: olay karartılan ekranı yeniden yakar (uzaktan
    /// çalışırken Tern'in gönderdiği olaylar zaten sayılır). Kilit ekranında da gönderilmez.
    private func appActivityTick() {
        guard isOn, settings.keepAppsActive, !remoteBlankActive, !remote.isScreenLocked() else { return }
        guard activity.secondsSinceLastInput() >= AppActivityPolicy.idleThreshold else { return }
        // Her dakika günlüğe yazılmaz; açılıştan sonra bir kez çalıştığı görülsün yeter.
        if activity.nudge(), !activityNudgeLogged {
            activityNudgeLogged = true
            log("Keep apps active: nudged the pointer in place (idle time reset)")
        }
    }

    /// macOS uykuya geçmek üzere. Pusu açıkken boşta uyku engellendiği için bu uyku elle verilmiştir
    /// (Uyut menüsü, kapak modu kapalıyken kapağı kapatmak, güç düğmesi). Ayar açıksa oturum biter.
    public func systemWillSleep() {
        guard isOn, settings.stopOnManualSleep else { return }
        log("Mac is going to sleep; turning Pusu off")
        stop(reason: .sleep, allowLidPrompt: false, wake: false)
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
        lines.append("  VNC mode: \(session.remoteBlankActive) (locked: \(session.remoteLocked), display asleep: \(session.remoteDisplaySlept), panel dark: \(session.remotePanelDark), virtual display: \(session.remoteVirtualDisplay), remote client: \(session.remoteClientConnected))")
        lines.append("  system assertion: \(session.assertions.isSystemHeld)")
        lines.append("  display assertion: \(session.assertions.isDisplayHeld)")
        lines.append("  user activity assertion: \(session.assertions.isUserActivityHeld)")
        lines.append("")

        lines.append("SETTINGS")
        lines.append("  keep display awake: \(settings.keepDisplayAwake)")
        lines.append("  keep session unlocked: \(settings.keepSessionUnlocked)")
        lines.append("  keep apps active: \(settings.keepAppsActive)")
        lines.append("  stop on manual sleep: \(settings.stopOnManualSleep)")
        lines.append("  remote access: \(settings.remoteKeepsDisplayOn ? "always on, dark" : "sleep until a connection"), lock: \(settings.remoteLockOnBlackout)")
        lines.append("  battery cutoff: \(percent(settings.batteryCutoffEnabled, settings.batteryCutoffPercent))")
        lines.append("  lid battery guard: \(percent(settings.lidBatteryFloorEnabled, settings.lidBatteryFloorPercent))")
        lines.append("  hotkey: \(settings.hotkeyPreset.rawValue)")
        lines.append("  launch at login: \(settings.launchAtLogin)")
        lines.append("  update check: \(settings.updateCheckEnabled ? "daily" : (settings.updateCheckAsked ? "manual" : "not asked yet"))")
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

        lines.append("RECENT EVENTS")
        let recent = EventLog.shared.tail(25)
        if recent.isEmpty {
            lines.append("  none")
        } else {
            for line in recent { lines.append("  \(line)") }
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

/// Uygulama içi güncellemede (Sparkle Pusu'yu kapatıp yenisini açar) açık oturumun yeni sürümde
/// kaldığı yerden sürmesi için kaydedilen durum. Uzak erişim modu sürdürülmez: güncellemeyi
/// onaylamak için ekran zaten kullanılıyordur.
public struct RelaunchState: Codable, Equatable {
    public var endDate: Date?
    public var lidMode: Bool
    public var savedAt: Date

    public init(endDate: Date?, lidMode: Bool, savedAt: Date) {
        self.endDate = endDate
        self.lidMode = lidMode
        self.savedAt = savedAt
    }

    static let key = "pusu.relaunchState"
    /// Bundan eski bir kayıt (güncelleme yarıda kaldıysa) yok sayılır.
    static let maxAge: TimeInterval = 10 * 60

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    /// Kaydı okur ve siler (bir kez kullanılır).
    public static func take(from defaults: UserDefaults = .standard, now: Date = Date()) -> RelaunchState? {
        defer { defaults.removeObject(forKey: key) }
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(RelaunchState.self, from: data),
              now.timeIntervalSince(state.savedAt) >= 0,
              now.timeIntervalSince(state.savedAt) < maxAge
        else { return nil }
        return state
    }
}

extension SessionController {
    /// Güncelleme öncesi kaydedilecek durum (kapalıysa `nil`).
    public func relaunchState(now: Date = Date()) -> RelaunchState? {
        guard isOn else { return nil }
        return RelaunchState(endDate: endDate, lidMode: lidMode, savedAt: now)
    }

    /// Güncellemeden sonra oturumu sürdürür. Süresi dolmuşsa açmaz. Kapak modu yalnızca yardımcı
    /// varsa, parola sormadan yeniden açılır.
    /// - Returns: Oturum açıldı mı?
    @discardableResult
    public func resume(_ state: RelaunchState, now: Date = Date()) -> Bool {
        let duration: PusuDuration
        if let end = state.endDate {
            let left = end.timeIntervalSince(now)
            guard left >= 1 else { return false }
            duration = PusuDuration(seconds: left)
        } else {
            duration = .indefinite
        }
        start(duration)
        guard isOn else { return false }
        log("Resumed after the update")
        if state.lidMode, lid.helperAvailable, !lidMode {
            setLidModeAsync(true, allowPrompt: false) { _ in }
        }
        return true
    }
}
