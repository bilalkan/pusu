import AppKit
import SwiftUI
import PusuCore

final class SettingsWindowController: NSWindowController {
    init(
        settings: SettingsStore,
        session: SessionController,
        history: SessionHistoryStore,
        updates: UpdateMonitor,
        actions: SettingsActions
    ) {
        let view = SettingsView(
            settings: settings,
            session: session,
            history: history,
            ui: SettingsUIModel(),
            updates: updates,
            actions: actions
        )
        let hostingController = NSHostingController(rootView: view)
        // Pencere boyutunu SwiftUI değil biz yönetelim (kayıtlı boyut + alt sınır).
        hostingController.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindowController.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = SettingsWindowController.title
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentMinSize = SettingsWindowController.minimumContentSize
        window.setContentSize(SettingsWindowController.defaultContentSize)
        window.center()
        // v2: eski, Oturum sekmesinin sığmadığı kayıtlı boyutlar geri yüklenmesin.
        window.setFrameAutosaveName("PusuSettingsWindow.v2")

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static var title: String { L("Pusu Ayarları", "Pusu Settings") }

    /// Oturum sekmesi (süreli oturum, en uzun hali) kaydırmadan sığar.
    static let defaultContentSize = NSSize(width: 720, height: 760)
    static let minimumContentSize = NSSize(width: 680, height: 560)

    func show() {
        guard let window else { return }
        fitToScreen(window)
        AppActivation.present(window)
    }

    /// Küçük ekranlarda pencere görünür alanı aşmasın.
    private func fitToScreen(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = window.frame
        if frame.height > visible.height { frame.size.height = visible.height }
        if frame.width > visible.width { frame.size.width = visible.width }
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        if frame != window.frame { window.setFrame(frame, display: false) }
    }

    func refreshTitle() {
        window?.title = SettingsWindowController.title
    }
}
