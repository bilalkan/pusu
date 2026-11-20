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
            for dark in [false, true] {
                let theme = dark ? "-dark" : ""
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
                        updates: UpdateMonitor(settings: fixture.settings, currentVersion: "dev") { _, _ in },
                        actions: .noop
                    )
                    let height: CGFloat
                    switch tab {
                    case .session: height = 762
                    case .history: height = 762
                    case .system, .settings: height = 788
                    }
                    render(
                        view,
                        size: NSSize(width: 720, height: height),
                        dark: dark,
                        title: L("Pusu Ayarları", "Pusu Settings"),
                        prepare: fixture.freezeClock,
                        to: outputDirectory.appendingPathComponent("settings-\(tab.rawValue)-\(language.rawValue)\(theme).png")
                    )
                }
                render(
                    AboutView {},
                    size: NSSize(width: 520, height: 360),
                    dark: dark,
                    title: nil,
                    to: outputDirectory.appendingPathComponent("about-\(language.rawValue)\(theme).png")
                )
            }
            fixture.tearDown()
        }
        Localization.force(nil)
        print(outputDirectory.path)
    }

    /// Görünümü ekran dışı bir pencerede çizer; sonucu macOS penceresi gibi yuvarlatılmış
    /// köşeli, gölgeli ve trafik ışıklı bir görsel olarak (saydam zeminde) kaydeder.
    private static func render<V: View>(
        _ view: V,
        size: NSSize,
        dark: Bool,
        title: String?,
        prepare: (() -> Void)? = nil,
        to url: URL
    ) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let previousAppearance = NSApp.appearance
        NSApp.appearance = appearance
        defer { NSApp.appearance = previousAppearance }

        let hosting = NSHostingView(rootView: view)
        hosting.appearance = appearance
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()

        for _ in 0..<6 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        // Gerçek 1 sn'lik zamanlayıcı örnek geri sayımı bozmasın: çizimden hemen önce sabitle.
        prepare?()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        hosting.layoutSubtreeIfNeeded()

        prepare?()
        hosting.layoutSubtreeIfNeeded()
        hosting.display()

        // Pencere sunucusundan yakalama, vibrancy kullanan denetimleri (sekme çubuğu) de
        // doğru çizer; uygulama kendi penceresini yakalarken ekran kaydı izni gerekmez.
        let bitmap: NSBitmapImageRep
        if let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ), image.width > 0 {
            bitmap = NSBitmapImageRep(cgImage: image)
        } else {
            guard let cached = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            appearance?.performAsCurrentDrawingAppearance {
                hosting.cacheDisplay(in: hosting.bounds, to: cached)
            }
            bitmap = cached
        }
        window.orderOut(nil)

        let scale = CGFloat(bitmap.pixelsWide) / size.width
        let margin: CGFloat = 36
        let canvasSize = NSSize(width: size.width + margin * 2, height: size.height + margin * 2)
        guard let canvas = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvasSize.width * scale),
            pixelsHigh: Int(canvasSize.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        canvas.size = canvasSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        let frame = NSRect(x: margin, y: margin, width: size.width, height: size.height)
        let shape = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.55 : 0.22)
        shadow.shadowBlurRadius = 22
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        bitmap.draw(in: frame)
        NSGraphicsContext.restoreGraphicsState()

        // Trafik ışıkları ve başlık (pencere başlık çubuğu saydam olduğu için içerik üstünde).
        let lights: [NSColor] = [
            NSColor(srgbRed: 1.00, green: 0.37, blue: 0.34, alpha: 1),
            NSColor(srgbRed: 1.00, green: 0.74, blue: 0.18, alpha: 1),
            NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1),
        ]
        for (index, color) in lights.enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: frame.minX + 14 + CGFloat(index) * 20,
                y: frame.maxY - 20,
                width: 12,
                height: 12
            )).fill()
        }
        if let title {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: dark
                    ? NSColor(white: 1, alpha: 0.55)
                    : NSColor(white: 0, alpha: 0.5),
            ]
            let text = NSAttributedString(string: title, attributes: attributes)
            let textSize = text.size()
            text.draw(at: NSPoint(x: frame.midX - textSize.width / 2, y: frame.maxY - 21))
        }

        // İnce kenarlık
        (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.12)).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        NSGraphicsContext.restoreGraphicsState()

        if let data = canvas.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }

    private static func iconFromRepository() -> URL? {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Icons/A/Pusu.icns")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Gerçekçi ama sahte bir oturum: 2 saatlik süre, pil %76, örnek geçmiş.
    private final class Fixture {
        let directory: URL
        let suite = "pusu.snapshot"
        let settings: SettingsStore
        let history: SessionHistoryStore
        let session: SessionController

        init() {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("pusu-snapshot-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
            settings.defaultDuration = .twoHours
            history = SessionHistoryStore(
                historyURL: directory.appendingPathComponent("history.json"),
                activeURL: directory.appendingPathComponent("active-session.json")
            )

            // Örnek geçmiş: zaman çizelgesi her saatte dolu görünsün diye "şimdi"ye göre.
            let now = Date()
            let samples: [(hoursAgo: Double, minutes: Double, reason: SessionStopReason, lid: Bool, remote: Bool)] = [
                (7.5, 95, .timer, false, false),
                (5.0, 40, .user, false, true),
                (3.2, 110, .user, true, false),
            ]
            for sample in samples {
                let start = now.addingTimeInterval(-sample.hoursAgo * 3600)
                history.begin(duration: PusuDuration(minutes: Int(sample.minutes)), at: start)
                if sample.lid { history.markLidUsed(at: start) }
                if sample.remote { history.markRemoteUsed(at: start) }
                history.end(
                    reason: sample.reason,
                    battery: BatteryStatus(percent: 80, isOnBattery: true, isCharging: false, isPresent: true),
                    at: start.addingTimeInterval(sample.minutes * 60)
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
            history.begin(duration: .twoHours, at: now.addingTimeInterval(-(35 * 60 + 50)))
            session.start(.twoHours)
            session.processTick(now: now.addingTimeInterval(35 * 60 + 50))
        }

        /// Geri sayımı "35 dk 50 sn geçmiş" durumuna sabitler (kalan 1:24:10).
        func freezeClock() {
            session.processTick(now: Date().addingTimeInterval(35 * 60 + 50))
        }

        func tearDown() {
            session.shutdown()
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suite).plist"))
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
        var helperResponding: Bool { true }
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
        remoteMode: {}, blackout: {}, lock: {}, wake: {}, openSharingSettings: {}, copyDiagnostics: {}, about: {},
        checkForUpdates: {}, showUpdate: {}
    )
}
#endif
