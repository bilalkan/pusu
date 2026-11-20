import Foundation
import PusuCore

/// SessionController'ı gerçek IOKit/pmset/ekran kilidine dokunmadan sürmek için sahte bileşenler.

final class FakeAssertions: PowerAsserting {
    private(set) var isSystemHeld = false
    private(set) var isDisplayHeld = false
    private(set) var isUserActivityHeld = false
    private(set) var acquireCount = 0
    private(set) var declareCount = 0

    func acquire(system: Bool, display: Bool, reason: String) -> Bool {
        acquireCount += 1
        isSystemHeld = system
        isDisplayHeld = display
        return true
    }

    func declareUserActivity(reason: String) -> Bool {
        declareCount += 1
        isUserActivityHeld = true
        return true
    }

    func releaseUserActivity() {
        isUserActivityHeld = false
    }

    func releaseAll() {
        isSystemHeld = false
        isDisplayHeld = false
        isUserActivityHeld = false
    }
}

final class FakeLid: LidControlling {
    var helperAvailable = true
    var usesFallback = false
    var sleepDisabledValue = false
    var failTurningOff = false
    private(set) var setCalls: [(enabled: Bool, allowPrompt: Bool)] = []

    func helperStatus() -> HelperStatus? {
        guard helperAvailable else { return nil }
        return HelperStatus(
            ok: true,
            version: HelperProtocol.version,
            sleepDisabled: sleepDisabledValue,
            original: sleepDisabledValue ? false : nil
        )
    }

    func sleepDisabled(timeout: TimeInterval) -> Bool? {
        sleepDisabledValue
    }

    func setEnabled(_ enabled: Bool, allowPrompt: Bool) throws {
        setCalls.append((enabled, allowPrompt))
        if !enabled, failTurningOff {
            throw HelperError.adminCancelled
        }
        sleepDisabledValue = enabled
    }
}

final class FakeRemote: RemoteControlling {
    var sharing: ScreenSharingState = .running
    private(set) var locked = false
    private(set) var lockCalls = 0
    private(set) var sleepCalls = 0
    private(set) var wakeCalls = 0

    func lockScreen() -> Bool {
        lockCalls += 1
        locked = true
        return true
    }

    func isScreenLocked() -> Bool { locked }

    func sleepDisplay() -> Bool {
        sleepCalls += 1
        return true
    }

    func wakeDisplay() -> Bool {
        wakeCalls += 1
        return true
    }

    func screenSharingState(timeout: TimeInterval) -> ScreenSharingState { sharing }

    func remoteManagementRunning(timeout: TimeInterval) -> Bool { false }
}

/// Bir SessionController ve sahte bağımlılıkları. Her harness kendi geçici dizinini kullanır.
final class SessionHarness {
    let directory: URL
    let defaultsSuite: String
    let settings: SettingsStore
    let assertions = FakeAssertions()
    let lid = FakeLid()
    let remote = FakeRemote()
    let history: SessionHistoryStore
    var battery: BatteryStatus?
    private(set) var runtimeStates: [RuntimeState] = []
    private(set) var events: [PusuEvent] = []
    private(set) var controller: SessionController!

    init(battery: BatteryStatus? = nil, configure: (SettingsStore) -> Void = { _ in }) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pusu-session-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaultsSuite = "pusu.tests.session.\(UUID().uuidString)"
        settings = SettingsStore(defaults: UserDefaults(suiteName: defaultsSuite)!)
        configure(settings)
        history = SessionHistoryStore(
            historyURL: directory.appendingPathComponent("history.json"),
            activeURL: directory.appendingPathComponent("active-session.json")
        )
        self.battery = battery
        controller = SessionController(
            settings: settings,
            assertions: assertions,
            lid: lid,
            remote: remote,
            history: history,
            batteryReader: { [unowned self] in self.battery },
            runtimeWriter: { [unowned self] state in self.runtimeStates.append(state) }
        )
        controller.onEvent = { [unowned self] event in self.events.append(event) }
    }

    var lastRuntime: RuntimeState? { runtimeStates.last }

    var stopReasons: [SessionStopReason] {
        events.compactMap { event in
            if case .stopped(let reason) = event { return reason }
            return nil
        }
    }

    /// Ana run loop'u, koşul sağlanana ya da süre dolana kadar döndürür.
    func spin(until condition: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func tearDown() {
        controller.shutdown()
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: directory)
    }
}

func battery(_ percent: Int, onBattery: Bool = true, charging: Bool = false) -> BatteryStatus {
    BatteryStatus(percent: percent, isOnBattery: onBattery, isCharging: charging, isPresent: true)
}
