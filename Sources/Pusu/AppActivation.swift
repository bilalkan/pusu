import AppKit

/// Menü çubuğu (accessory) uygulamasında pencereleri gerçekten öne getirir.
///
/// macOS 14'ten itibaren etkinleştirme "işbirlikçi"; arka plandan gelen bir istek
/// (CLI, URL, dağıtık bildirim) `activate(ignoringOtherApps:)` ile odak alamayabilir.
/// `orderFrontRegardless` pencereyi her durumda görünür kılar.
enum AppActivation {
    static func activate() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    static func present(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
