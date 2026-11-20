import AppKit
import SwiftUI
import PusuCore

struct AboutView: View {
    var onClose: () -> Void

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? CLI.version
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 76, height: 76)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Pusu")
                        .font(.system(size: 26, weight: .semibold))
                    Text(L("Sürüm \(version) (\(build))", "Version \(version) (\(build))"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            Divider()
                .padding(.vertical, 16)

            VStack(alignment: .leading, spacing: 11) {
                Text(L("Pusu, Mac'in uyanık kalmasını sağlayan bir menü çubuğu uygulamasıdır.", "Pusu is a menu bar app that keeps your Mac awake."))
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)

                Text(L(
                    "Sistemin ve ekranın uykuya geçmesini engeller. Belirli bir süre için çalışabilir, ayarladığınız pil seviyesinde otomatik kapanır. Kapak kapalıyken de Mac'in çalışmaya devam etmesini sağlar; VNC/uzak erişim sırasında ekranı karartıp oturumu kilitleyebilir.",
                    "It stops the system and the display from going to sleep. It can run for a set time and turns itself off at the battery level you choose. It can keep the Mac running with the lid closed, and during VNC/remote access it can turn the display off and lock the session."
                ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    FeatureBadge(icon: "bolt.fill", title: L("Sistem", "System"))
                    FeatureBadge(icon: "display", title: L("Ekran", "Display"))
                    FeatureBadge(icon: "laptopcomputer", title: L("Kapak", "Lid"))
                    FeatureBadge(icon: "network", title: "VNC")
                }
                .padding(.vertical, 2)

                Text(L(
                    "IOKit power assertion'ları ve pmset kullanır. Kapak modu için isteğe bağlı yönetici yardımcısı gerekir.",
                    "Uses IOKit power assertions and pmset. Lid mode can use an optional privileged helper."
                ))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("© 2026 Pusu · GPL-3.0")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Link(PusuLinks.repositoryDisplay, destination: PusuLinks.repository)
                        .font(.system(size: 11))
                }

                Spacer()

                Button(L("Kapat", "Close"), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(28)
        .frame(width: 520, height: 360)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .underPageBackgroundColor).opacity(0.55),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

private struct FeatureBadge: View {
    let icon: String
    let title: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

final class AboutWindowController: NSWindowController {
    init() {
        let hostingController = NSHostingController(
            rootView: AboutView {
                NSApp.keyWindow?.performClose(nil)
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AboutWindowController.title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = hostingController
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static var title: String { L("Pusu Hakkında", "About Pusu") }

    func show() {
        guard let window else { return }
        // Dil değişmiş olabilir; içerik her açılışta yeniden çizilir.
        (contentViewController as? NSHostingController<AboutView>)?.rootView = AboutView {
            NSApp.keyWindow?.performClose(nil)
        }
        AppActivation.present(window)
    }

    func refreshTitle() {
        window?.title = AboutWindowController.title
    }
}

/// Proje bağlantıları (About, Ayarlar ve README ile aynı).
enum PusuLinks {
    static let repository = URL(string: "https://github.com/bilalkan/pusu")!
    static let repositoryDisplay = "github.com/bilalkan/pusu"
    static let issues = URL(string: "https://github.com/bilalkan/pusu/issues")!
}
