#if DEBUG
import AppKit
import SwiftUI
import PusuCore

/// Geliştirici aracı: Ayarlar ve Hakkında pencerelerini sahte verilerle ekran dışı bir
/// pencerede çizer ve PNG olarak kaydeder. Ekran kaydı izni gerektirmez; kullanıcının
/// ayarlarına, geçmişine veya `runtime.json` dosyasına dokunmaz.
///
///     swift run Pusu --snapshot-ui /tmp/pusu-shots
enum UISnapshot {
    static func run(outputDirectory: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        if let url = Bundle.main.url(forResource: "Pusu", withExtension: "icns") ?? iconFromRepository(),
           let image = NSImage(contentsOf: url) {
            app.applicationIconImage = image
        }
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        for language in [AppLanguage.turkish, .english] {
            Localization.force(language)
            let fixture = Fixture()
            for tab in SettingsTab.allCases {
                let ui = SettingsUIModel()
                ui.isSnapshot = true
                ui.tab = tab
                ui.helperLoaded = true
                ui.helperStatus = HelperStatus(ok: true, version: HelperProtocol.version, sleepDisabled: false)
                ui.sleepDisabled = false
                ui.lidSnapshot = LidSnapshot(isClosed: false, causesSleep: true)
                ui.sharingState = .running
                ui.notificationsAuthorized = true
                ui.diagnostics = "Pusu \(CLI.version)\nmacOS: …\n\nSTATE\n  on: true\n  remaining: 1:24:10\n  lid mode: false\n…"
                let view = SettingsView(
                    settings: fixture.settings,
                    session: fixture.session,
                    history: fixture.history,
                    ui: ui,
                    actions: .noop
                )
                render(view, size: NSSize(width: 720, height: 788), to: outputDirectory
                    .appendingPathComponent("settings-\(tab.rawValue)-\(language.rawValue).png"))
            }
            render(AboutView {}, size: NSSize(width: 520, height: 360), to: outputDirectory
                .appendingPathComponent("about-\(language.rawValue).png"))
            fixture.tearDown()
        }
        Localization.force(nil)
        print(outputDirectory.path)
    }

    private static func render<V: View>(_ view: V, size: NSSize, to url: URL) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()

        for _ in 0..<6 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
        window.orderOut(nil)
    }

    private static func iconFromRepository() -> URL? {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Icons/A/Pusu.icns")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Gerçekçi ama sahte bir oturum: 2 saatlik süre, pil %76, örnek geçmiş.
    private final class Fixture {
        let directory: URL
        let suite = "pusu.snapshot.\(UUID().uuidString)"
        let settings: SettingsStore
        let history: SessionHistoryStore
        let session: SessionController

        init() {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("pusu-snapshot-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
            settings.defaultDuration = .twoHours
            settings.language = Localization.resolved
            history = SessionHistoryStore(
                historyURL: directory.appendingPathComponent("history.json"),
                activeURL: directory.appendingPathComponent("active-session.json")
            )

            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let samples: [(start: Double, minutes: Double, reason: SessionStopReason, lid: Bool, remote: Bool)] = [
                (8.5, 95, .timer, false, false),
                (10.75, 40, .user, false, true),
                (12.9, 130, .user, true, false),
            ]
            for sample in samples {
                let start = today.addingTimeInterval(sample.start * 3600)
                guard start < Date() else { continue }
                history.begin(duration: PusuDuration(minutes: Int(sample.minutes)), at: start)
                if sample.lid { history.markLidUsed(at: start) }
                if sample.remote { history.markRemoteUsed(at: start) }
                history.end(
                    reason: sample.reason,
                    battery: BatteryStatus(percent: 80, isOnBattery: true, isCharging: false, isPresent: true),
                    at: min(Date(), start.addingTimeInterval(sample.minutes * 60))
                )
            }

            session = SessionController(
                settings: settings,
                assertions: SnapshotAssertions(),
                lid: SnapshotLid(),
                remote: SnapshotRemote(),
                history: history,
                batteryReader: {
                    BatteryStatus(percent: 76, isOnBattery: true, isCharging: false, isPresent: true, minutesRemaining: 252)
                },
                runtimeWriter: { _ in }
            )
            session.start(.twoHours)
            session.processTick(now: Date().addingTimeInterval(35 * 60 + 50))
        }

        func tearDown() {
            session.shutdown()
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private final class SnapshotAssertions: PowerAsserting {
        private(set) var isSystemHeld = false
        private(set) var isDisplayHeld = false
        private(set) var isUserActivityHeld = false
        func acquire(system: Bool, display: Bool, reason: String) -> Bool {
            isSystemHeld = system
            isDisplayHeld = display
            return true
        }
        func declareUserActivity(reason: String) -> Bool { isUserActivityHeld = true; return true }
        func releaseUserActivity() { isUserActivityHeld = false }
        func releaseAll() { isSystemHeld = false; isDisplayHeld = false; isUserActivityHeld = false }
    }

    private final class SnapshotLid: LidControlling {
        var helperAvailable: Bool { true }
        var usesFallback: Bool { false }
        func helperStatus() -> HelperStatus? { HelperStatus(version: HelperProtocol.version) }
        func sleepDisabled(timeout: TimeInterval) -> Bool? { false }
        func setEnabled(_ enabled: Bool, allowPrompt: Bool) throws {}
    }

    private final class SnapshotRemote: RemoteControlling {
        func lockScreen() -> Bool { true }
        func isScreenLocked() -> Bool { false }
        func sleepDisplay() -> Bool { true }
        func wakeDisplay() -> Bool { true }
        func screenSharingState(timeout: TimeInterval) -> ScreenSharingState { .running }
        func remoteManagementRunning(timeout: TimeInterval) -> Bool { false }
    }
}

extension SettingsActions {
    static let noop = SettingsActions(
        toggle: {}, start: { _ in }, stop: {}, setLid: { _ in }, installHelper: {}, removeHelper: {},
        remoteMode: {}, blackout: {}, lock: {}, wake: {}, openSharingSettings: {}, copyDiagnostics: {}, about: {}
    )
}
#endif
