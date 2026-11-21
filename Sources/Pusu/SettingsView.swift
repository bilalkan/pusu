import SwiftUI
import AppKit
import Combine
import UserNotifications
import PusuCore

struct SettingsActions {
    var toggle: () -> Void
    var start: (PusuDuration) -> Void
    var stop: () -> Void
    var setLid: (Bool) -> Void
    var installHelper: () -> Void
    var removeHelper: () -> Void
    var remoteMode: () -> Void
    var blackout: () -> Void
    var lock: () -> Void
    var wake: () -> Void
    var openSharingSettings: () -> Void
    var copyDiagnostics: () -> Void
    var about: () -> Void
    var checkForUpdates: () -> Void
    var showUpdate: () -> Void
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case session
    case history
    case system
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .session: return L("Oturum", "Session")
        case .history: return L("Geçmiş", "History")
        case .system: return L("Sistem", "System")
        case .settings: return L("Ayarlar", "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .session: return "bolt.fill"
        case .history: return "clock.arrow.circlepath"
        case .system: return "cpu"
        case .settings: return "gearshape"
        }
    }
}

/// Ayarlar penceresinin arayüz durumu. Bu ortamda `@State` makrosu güvenilir olmadığı için
/// pencere durumu burada tutulur.
final class SettingsUIModel: ObservableObject {
    @Published var tab: SettingsTab = .session
    @Published var helperStatus: HelperStatus?
    @Published var helperLoaded = false
    @Published var diagnostics = ""
    @Published var copied = false
    @Published var helperBusy = false
    @Published var lidSnapshot = LidSnapshot(isClosed: nil, causesSleep: nil)
    @Published var sleepDisabled: Bool?
    @Published var sharingState: ScreenSharingState = .unknown
    @Published var remoteManagement = false
    @Published var notificationsAuthorized: Bool?
    @Published var showHistoryClearConfirmation = false
    /// Geliştirici ekran görüntüsü aracı: canlı sistem durumunu okumaz.
    var isSnapshot = false

    private var refreshing = false
    private var diagnosticsRefreshing = false

    var helperIsCurrent: Bool { HelperProtocol.isCurrent(helperStatus) }

    /// Yardımcı, kapak ve uzak erişim durumunu arka planda okur.
    func refreshStatus(settings: SettingsStore) {
        guard !isSnapshot else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] notificationSettings in
            let authorized: Bool?
            switch notificationSettings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: authorized = true
            case .denied: authorized = false
            case .notDetermined: authorized = nil
            @unknown default: authorized = nil
            }
            DispatchQueue.main.async { self?.notificationsAuthorized = authorized }
        }

        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let helper = HelperClient.status(timeout: 1)
            let lid = LidStateReader.read()
            let sleepDisabled = LidController(settings: settings).sleepDisabled(timeout: 5)
            let remote = RemoteController()
            let sharing = remote.screenSharingState(timeout: 5)
            let remoteManagement = remote.remoteManagementRunning(timeout: 5)
            DispatchQueue.main.async {
                guard let self else { return }
                self.helperStatus = helper
                self.helperLoaded = true
                self.lidSnapshot = lid
                self.sleepDisabled = sleepDisabled
                self.sharingState = sharing
                self.remoteManagement = remoteManagement
                self.helperBusy = false
                self.refreshing = false
            }
        }
    }

    /// Tanılama `pmset`/`launchctl` çalıştırır; ana thread'i bloklamamak için arka planda üretilir.
    func refreshDiagnostics(session: SessionController) {
        guard !isSnapshot, !diagnosticsRefreshing else { return }
        diagnosticsRefreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let text = session.diagnostics(appVersion: CLI.version)
            DispatchQueue.main.async {
                self?.diagnostics = text
                self?.diagnosticsRefreshing = false
            }
        }
    }
}

// MARK: - Root

/// Kök görünüm yalnızca ayarları ve pencere durumunu gözler. Oturum durumu ve saniyelik
/// geri sayım, onlara ihtiyaç duyan küçük alt görünümlerde gözlenir; böylece Pusu açıkken
/// bütün pencere her saniye yeniden çizilmez.
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    let session: SessionController
    let history: SessionHistoryStore
    @ObservedObject var ui: SettingsUIModel
    let updates: UpdateMonitor
    let actions: SettingsActions

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(session: session, clock: session.clock, actions: actions)
            SessionErrorBanner(session: session)
            Divider()
            TabView(selection: $ui.tab) {
                SessionTabView(settings: settings, session: session, history: history, ui: ui, actions: actions)
                    .tabItem { Label(SettingsTab.session.title, systemImage: SettingsTab.session.symbol) }
                    .tag(SettingsTab.session)
                SessionHistoryView(history: history, ui: ui)
                    .tabItem { Label(SettingsTab.history.title, systemImage: SettingsTab.history.symbol) }
                    .tag(SettingsTab.history)
                SystemTabView(settings: settings, session: session, ui: ui, actions: actions)
                    .tabItem { Label(SettingsTab.system.title, systemImage: SettingsTab.system.symbol) }
                    .tag(SettingsTab.system)
                PreferencesTabView(settings: settings, ui: ui, updates: updates, actions: actions)
                    .tabItem { Label(SettingsTab.settings.title, systemImage: SettingsTab.settings.symbol) }
                    .tag(SettingsTab.settings)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .frame(minWidth: 680, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if !ui.isSnapshot { restoreSelectedTab() }
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pusuHelperChanged)) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pusuStateChanged)) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // Pencere öne geldiğinde (ör. Sistem Ayarları'ndan dönüş) durumu tazele.
            if (note.object as? NSWindow)?.title == L("Pusu Ayarları", "Pusu Settings") { refresh() }
        }
        .onChange(of: ui.tab) { newTab in
            UserDefaults.standard.set(newTab.rawValue, forKey: "pusu.settingsTab")
            refresh()
        }
    }

    private func refresh() {
        ui.refreshStatus(settings: settings)
        if ui.tab == .system { ui.refreshDiagnostics(session: session) }
    }

    private func restoreSelectedTab() {
        guard let raw = UserDefaults.standard.string(forKey: "pusu.settingsTab"),
              let tab = SettingsTab(rawValue: raw)
        else { return }
        ui.tab = tab
    }
}

// MARK: - Header

private struct SettingsHeader: View {
    @ObservedObject var session: SessionController
    @ObservedObject var clock: SessionClock
    let actions: SettingsActions

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Pusu")
                        .font(.system(size: 20, weight: .semibold))
                    StatusPill(isOn: session.isOn)
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            Button(session.isOn ? L("Kapat", "Turn Off") : L("Başlat", "Turn On")) {
                actions.toggle()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var subtitle: String {
        if session.isOn, let remaining = clock.remaining {
            return L("Açık · \(TimeText.countdown(remaining)) kaldı", "On · \(TimeText.countdown(remaining)) left")
        }
        if session.isOn {
            return L("Süresiz açık · sistem uyku moduna geçmeyecek", "On indefinitely · the system won't sleep")
        }
        return L("Kapalı · sistem normal şekilde uyuyabilir", "Off · the system can sleep normally")
    }
}

private struct StatusPill: View {
    let isOn: Bool

    var body: some View {
        Text(isOn ? L("AÇIK", "ON") : L("KAPALI", "OFF"))
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill((isOn ? Color.green : Color.secondary).opacity(0.18))
            )
            .foregroundStyle(isOn ? Color.green : Color.secondary)
    }
}

private struct SessionErrorBanner: View {
    @ObservedObject var session: SessionController

    var body: some View {
        if let error = session.lastError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(L("Kapat", "Dismiss")) { session.clearError() }
                    .buttonStyle(.link)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.08))
        }
    }
}

// MARK: - Session tab

private struct SessionTabView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var session: SessionController
    @ObservedObject var history: SessionHistoryStore
    @ObservedObject var ui: SettingsUIModel
    let actions: SettingsActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summaryCard
                modesCard
                awakeOptionsCard
            }
            .padding(.vertical, 14)
        }
        .scrollIndicators(.visible)
    }

    private var summaryCard: some View {
        SettingsCard(
            title: L("Şu anki oturum", "Current session"),
            subtitle: L("Pusu açıkken sistem uyku moduna geçmez.", "While Pusu is on, the system doesn't go to sleep.")
        ) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.isOn ? L("Açık", "On") : L("Kapalı", "Off"))
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.primary)
                    if session.isOn {
                        SessionCountdownLine(clock: session.clock)
                    } else {
                        Text(L("Sistem uyku moduna geçebilir", "The system can go to sleep"))
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                Spacer()

                if let battery = session.battery, battery.isPresent {
                    VStack(alignment: .trailing, spacing: 3) {
                        Label(Localization.percent(battery.percent), systemImage: batterySymbol(battery))
                            .font(.callout.weight(.medium))
                        Text(battery.isOnBattery ? L("Pilde", "On battery") : L("Güç bağlı", "Plugged in"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if session.isOn {
                if let total = session.duration?.seconds, total > 0 {
                    SessionProgressBar(clock: session.clock, total: total)
                        .padding(.top, 2)
                }

                HStack(spacing: 12) {
                    if let start = history.active?.startedAt {
                        Label(L("Başlangıç: \(TimeText.clock(start))", "Started: \(TimeText.clock(start))"), systemImage: "play.circle")
                    }
                    if let battery = session.battery, let remaining = battery.remainingLabel {
                        Label(L("Pil: \(remaining)", "Battery: \(remaining)"), systemImage: "battery.50")
                    }
                    Spacer()
                    if session.lidMode {
                        Label(L("Kapak", "Lid"), systemImage: "laptopcomputer")
                    }
                    if session.remoteBlankActive {
                        Label("VNC", systemImage: "display")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var modesCard: some View {
        let canRemote = ui.sharingState == .running || ui.remoteManagement || TernClientWatcher.isInstalled
        let vncSubtitle: String
        if session.remoteBlankActive {
            if session.remoteVirtualDisplay {
                vncSubtitle = L("Açık · kapak kapalı, sanal ekran açık", "On · lid closed, virtual display on")
            } else if session.remotePanelDark {
                vncSubtitle = L("Açık · ekran açık ama karanlık", "On · display on but dark")
            } else {
                vncSubtitle = L("Açık · ekran uyuyor, bağlantı bekleniyor", "On · display asleep, waiting for a connection")
            }
        } else if canRemote {
            vncSubtitle = settings.remoteLockOnBlackout
                ? L("Ekranı kapat, oturumu kilitle", "Turn the display off and lock the session")
                : L("Ekranı kapat, oturum açık kalsın", "Turn the display off, keep the session unlocked")
        } else {
            vncSubtitle = L("Ekran Paylaşımı kapalı", "Screen Sharing is off")
        }

        let lidSubtitle: String
        if session.lidMode {
            lidSubtitle = L("Açık · kapak kapalıyken sistem uyanık kalır", "On · the system stays awake with the lid closed")
        } else if ui.helperLoaded, ui.helperStatus == nil {
            lidSubtitle = L("Kapak kapalıyken de çalışmaya devam et · yönetici izni gerekir", "Keep working with the lid closed · needs administrator permission")
        } else {
            lidSubtitle = L("Kapak kapalıyken de çalışmaya devam et", "Keep working with the lid closed")
        }

        return SettingsCard(
            title: L("Modlar", "Modes"),
            subtitle: L("Kapak modu ve uzak erişim birbirinden bağımsız açılabilir.", "Lid mode and remote access can be turned on independently.")
        ) {
            ModeRow(
                icon: "laptopcomputer",
                title: L("Kapak modu", "Lid mode"),
                subtitle: lidSubtitle,
                active: session.lidMode,
                actionTitle: session.lidMode ? L("Kapat", "Turn Off") : L("Aç", "Turn On")
            ) {
                actions.setLid(!session.lidMode)
            }

            Divider()

            ModeRow(
                icon: "display",
                title: L("Uzak erişim (VNC)", "Remote access (VNC)"),
                subtitle: vncSubtitle,
                active: session.remoteBlankActive,
                actionTitle: session.remoteBlankActive ? L("Kapat", "Turn Off") : L("Başlat", "Start"),
                actionDisabled: !session.remoteBlankActive && !canRemote
            ) {
                if session.remoteBlankActive {
                    actions.wake()
                } else {
                    actions.remoteMode()
                }
            }

            if !canRemote && !session.remoteBlankActive {
                Button(L("Ekran Paylaşımı Ayarları…", "Screen Sharing Settings…")) {
                    actions.openSharingSettings()
                }
                .buttonStyle(.link)
            }

            Divider()

            SettingRow(
                title: L("Uzak erişimde oturumu kilitle", "Lock the session for remote access"),
                subtitle: L("Kapalıysa yalnızca ekran karartılır; oturum açık kalır.", "When off, only the display is turned off; the session stays unlocked.")
            ) {
                SettingsToggle(title: L("Uzak erişimde oturumu kilitle", "Lock the session for remote access"), isOn: $settings.remoteLockOnBlackout)
            }

            Divider()

            SettingRow(
                title: L("Ekranı hiç uyutma (diğer uygulamalar için)", "Never sleep the display (for other apps)"),
                subtitle: L(
                    "Normalde ekran bağlantı gelene kadar uyur. Tern bağlanınca ekran uyanır ama panel karanlık kalır; Apple Ekran Paylaşımı ekranı kendisi uyandırır. Başka bir uzak erişim uygulaması kullanıyorsan bunu aç: ekran hep açık ama karanlık kalır (yaklaşık 2 W). Kapak modu açıkken ekran zaten uyutulmaz; kapak kapanınca uzak bağlantı için sanal ekran açılır.",
                    "Normally the display sleeps until a connection. When Tern connects, the display wakes but the panel stays dark; Apple Screen Sharing wakes the display itself. If you use another remote access app, turn this on: the display stays on but dark (about 2 W). With lid mode on the display never sleeps; when the lid closes, a virtual display is used for remote connections."
                )
            ) {
                SettingsToggle(title: L("Ekranı hiç uyutma (diğer uygulamalar için)", "Never sleep the display (for other apps)"), isOn: $settings.remoteKeepsDisplayOn)
            }

            if session.lidMode, session.battery?.isOnBattery == true {
                WarningCard(text: settings.lidBatteryFloorEnabled
                    ? L(
                        "Kapak modu pildeyken ekstra tüketim ve ısınma yapabilir. Kapak pil koruması \(Localization.percent(settings.lidBatteryFloorPercent)) eşiğinde devreye girer.",
                        "Lid mode on battery can use more power and get warm. The lid battery guard kicks in at \(Localization.percent(settings.lidBatteryFloorPercent))."
                    )
                    : L(
                        "Kapak modu pildeyken ekstra tüketim ve ısınma yapabilir. Kapak pil koruması şu anda kapalı.",
                        "Lid mode on battery can use more power and get warm. The lid battery guard is currently off."
                    )
                )
            }
        }
    }

    private var awakeOptionsCard: some View {
        SettingsCard(
            title: L("Uyanık kalma", "Staying awake"),
            subtitle: L("Bu oturumun davranışı.", "How this session behaves.")
        ) {
            SettingRow(
                title: L("Ekran açık kalsın", "Keep the display awake"),
                subtitle: L("Ekranın uyumasını da engeller. Kapalıysa sadece sistem uyanık kalır.", "Also stops the display from sleeping. When off, only the system stays awake.")
            ) {
                SettingsToggle(title: L("Ekran açık kalsın", "Keep the display awake"), isOn: $settings.keepDisplayAwake)
            }
            Divider()
            SettingRow(
                title: L("Oturum kilitlenmesin", "Keep the session unlocked"),
                subtitle: L(
                    "Ekran koruyucu ve otomatik kilit devreye girmez. Her 30 saniyede kullanıcı etkinliği bildirir.",
                    "The screen saver and auto-lock won't kick in. Pusu reports user activity every 30 seconds."
                )
            ) {
                SettingsToggle(title: L("Oturum kilitlenmesin", "Keep the session unlocked"), isOn: $settings.keepSessionUnlocked)
            }
        }
    }

    private func batterySymbol(_ battery: BatteryStatus) -> String {
        if !battery.isPresent { return "desktopcomputer" }
        if battery.isCharging { return "battery.100.bolt" }
        if battery.percent <= 20 { return "battery.25" }
        return "battery.100"
    }
}

/// Saniyede bir yenilenen tek satır; yalnızca `SessionClock`'u gözler.
private struct SessionCountdownLine: View {
    @ObservedObject var clock: SessionClock

    var body: some View {
        if let remaining = clock.remaining {
            Text(L("Kalan: \(TimeText.countdown(remaining))", "Remaining: \(TimeText.countdown(remaining))"))
                .monospacedDigit()
        } else {
            Text(L("Süresiz", "Indefinitely"))
        }
    }
}

private struct SessionProgressBar: View {
    @ObservedObject var clock: SessionClock
    let total: TimeInterval

    var body: some View {
        let remaining = clock.remaining ?? total
        let fraction = min(1, max(0, (total - remaining) / total))
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(6, proxy.size.width * fraction))
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel(L("Geçen süre", "Elapsed"))
        .accessibilityValue(Text("\(Int(fraction * 100))%"))
    }
}

// MARK: - System tab

private struct SystemTabView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var session: SessionController
    @ObservedObject var ui: SettingsUIModel
    let actions: SettingsActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                batteryCard
                helperCard
                remoteStatusCard
                diagnosticsCard
            }
            .padding(.vertical, 14)
        }
        .scrollIndicators(.visible)
    }

    private var batteryCard: some View {
        SettingsCard(
            title: L("Pil", "Battery"),
            subtitle: L("Mevcut güç kaynağı ve pil süresi.", "Current power source and battery time.")
        ) {
            if let battery = session.battery, battery.isPresent {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Localization.percent(battery.percent))
                        .font(.system(size: 28, weight: .semibold))
                    Text(battery.isOnBattery ? L("Pilde", "On battery") : L("Güç bağlı", "Plugged in"))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                StatusLine(title: L("Durum", "Status"), value: battery.powerLabel)
                StatusLine(title: L("Kalan süre", "Time remaining"), value: battery.remainingLabel ?? "—")
                StatusLine(
                    title: L("Pil eşiği", "Battery threshold"),
                    value: settings.batteryCutoffEnabled ? Localization.percent(settings.batteryCutoffPercent) : L("kapalı", "off")
                )
            } else {
                Text(L("Bu Mac'te pil yok ya da pil bilgisi okunamıyor.", "This Mac has no battery, or battery info isn't available."))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var helperText: String {
        guard ui.helperLoaded else { return L("kontrol ediliyor…", "checking…") }
        guard let status = ui.helperStatus else {
            return HelperInstaller.daemonPlistExists
                ? L("kurulu ama yanıt vermiyor", "installed but not responding")
                : L("kurulu değil", "not installed")
        }
        if ui.helperIsCurrent {
            return L("çalışıyor · v\(status.version ?? "-")", "running · v\(status.version ?? "-")")
        }
        return L(
            "eski sürüm · v\(status.version ?? "-") (güncel: v\(HelperProtocol.version))",
            "outdated · v\(status.version ?? "-") (current: v\(HelperProtocol.version))"
        )
    }

    private var helperCard: some View {
        let plistExists = HelperInstaller.daemonPlistExists
        let installed = ui.helperStatus != nil || plistExists
        let installTitle: String
        if ui.helperBusy {
            installTitle = L("İşleniyor…", "Working…")
        } else if ui.helperStatus != nil, !ui.helperIsCurrent {
            installTitle = L("Yardımcıyı güncelle…", "Update Helper…")
        } else if installed {
            installTitle = L("Yeniden kur…", "Reinstall…")
        } else {
            installTitle = L("Yardımcıyı kur…", "Install Helper…")
        }

        return SettingsCard(
            title: L("Kapak modu ve yardımcı", "Lid mode and helper"),
            subtitle: L("Kapak kapalıyken uyumayı engelleyen pmset ayarı.", "The pmset setting that prevents sleep with the lid closed.")
        ) {
            StatusLine(title: "SleepDisabled", value: ui.sleepDisabled.map { $0 ? "1" : "0" } ?? L("bilinmiyor", "unknown"))
            StatusLine(title: L("Kapak durumu", "Lid"), value: ui.lidSnapshot.isClosedLabel)
            StatusLine(title: L("Yardımcı", "Helper"), value: helperText)

            HStack(spacing: 10) {
                if !(ui.helperStatus != nil && ui.helperIsCurrent) {
                    Button(installTitle) {
                        ui.helperBusy = true
                        actions.installHelper()
                    }
                    .disabled(ui.helperBusy)
                }

                Button(L("Yardımcıyı kaldır…", "Remove Helper…")) {
                    actions.removeHelper()
                }
                .disabled(!installed || ui.helperBusy)

                Button(L("Durumu yenile", "Refresh")) {
                    ui.refreshStatus(settings: settings)
                }
            }

            Text(L(
                "Kurulum bir kez yönetici parolası ister. Sonrasında kapak modu tek tıkla çalışır.",
                "Installing asks for your administrator password once. After that, lid mode is a single click."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var remoteStatusCard: some View {
        SettingsCard(
            title: L("Uzak erişim durumu", "Remote access status"),
            subtitle: L("VNC için gerekli macOS servisleri ve güç assertion'ları.", "macOS services needed for VNC, and power assertions.")
        ) {
            StatusLine(title: L("Ekran Paylaşımı", "Screen Sharing"), value: ui.sharingState.label)
            StatusLine(title: "ARDAgent", value: ui.remoteManagement ? L("çalışıyor", "running") : L("çalışmıyor", "not running"))
            StatusLine(title: L("Sistem assertion", "System assertion"), value: session.assertions.isSystemHeld ? L("aktif", "active") : L("yok", "none"))
            StatusLine(title: L("Ekran assertion", "Display assertion"), value: session.assertions.isDisplayHeld ? L("aktif", "active") : L("yok", "none"))

            HStack(spacing: 8) {
                Button(L("Ekranı karart", "Turn Display Off")) { actions.blackout() }
                Button(L("Ekranı kilitle", "Lock Screen")) { actions.lock() }
                Button(L("Ekranı uyandır", "Wake Display")) { actions.wake() }
                Spacer()
            }
            .padding(.top, 4)

            HStack {
                Button(L("Ekran Paylaşımı Ayarları…", "Screen Sharing Settings…")) {
                    actions.openSharingSettings()
                }
                Spacer()
            }
        }
    }

    private var diagnosticsCard: some View {
        SettingsCard(
            title: L("Tanılama", "Diagnostics"),
            subtitle: L(
                "Hata bildirirken bu metni ekleyin (İngilizce üretilir).",
                "Attach this text when you report a bug."
            )
        ) {
            HStack {
                Text(ui.diagnostics.isEmpty ? L("Yükleniyor…", "Loading…") : L("Tanılama hazır", "Diagnostics ready"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("Yenile", "Refresh")) { ui.refreshDiagnostics(session: session) }
                Button(ui.copied ? L("Kopyalandı", "Copied") : L("Kopyala", "Copy")) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(ui.diagnostics, forType: .string)
                    ui.copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { ui.copied = false }
                }
                .disabled(ui.diagnostics.isEmpty)
            }

            ScrollView {
                Text(ui.diagnostics.isEmpty ? L("Yükleniyor…", "Loading…") : ui.diagnostics)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 220)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
        }
    }
}

// MARK: - Preferences tab

private struct PreferencesTabView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var ui: SettingsUIModel
    @ObservedObject var updates: UpdateMonitor
    let actions: SettingsActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                defaultsCard
                startupCard
                notificationsCard
                hotkeyCard
                languageCard
                updatesCard
                aboutCard
                filesCard
            }
            .padding(.vertical, 14)
        }
        .scrollIndicators(.visible)
    }

    private var defaultsCard: some View {
        SettingsCard(
            title: L("Varsayılanlar", "Defaults"),
            subtitle: L("Pusu başladığında ve yeni oturumlarda kullanılan değerler.", "Values used when Pusu starts and for new sessions.")
        ) {
            SettingRow(
                title: L("Varsayılan süre", "Default duration"),
                subtitle: L("Başlat veya kısayol kullanıldığında uygulanır.", "Used when you click Turn On or press the shortcut.")
            ) {
                Picker("", selection: $settings.defaultDuration) {
                    ForEach(PusuDuration.presets) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }

            Divider()

            SettingRow(
                title: L("Pil eşiğinde kapat", "Turn off at battery threshold"),
                subtitle: L("Pil belirtilen yüzdenin altına inince oturum kapanır.", "The session ends when the battery drops below this level.")
            ) {
                SettingsToggle(title: L("Pil eşiğinde kapat", "Turn off at battery threshold"), isOn: $settings.batteryCutoffEnabled)
            }
            if settings.batteryCutoffEnabled {
                SettingRow(title: L("Pil eşiği", "Battery threshold"), subtitle: nil) {
                    Picker("", selection: $settings.batteryCutoffPercent) {
                        ForEach([5, 10, 15, 20, 25], id: \.self) { value in
                            Text(Localization.percent(value)).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
            }

            Divider()

            SettingRow(
                title: L("Kapak pil koruması", "Lid battery guard"),
                subtitle: L("Kapak modu pildeyken belirtilen eşiğin altında otomatik kapanır.", "Lid mode turns itself off on battery below this level.")
            ) {
                SettingsToggle(title: L("Kapak pil koruması", "Lid battery guard"), isOn: $settings.lidBatteryFloorEnabled)
            }
            if settings.lidBatteryFloorEnabled {
                SettingRow(title: L("Kapak eşiği", "Lid threshold"), subtitle: nil) {
                    Picker("", selection: $settings.lidBatteryFloorPercent) {
                        ForEach([10, 15, 20, 25, 30], id: \.self) { value in
                            Text(Localization.percent(value)).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
            }
        }
    }

    private var startupCard: some View {
        SettingsCard(
            title: L("Başlangıç", "Startup"),
            subtitle: L("Uygulama ve oturum davranışı.", "App and session behavior.")
        ) {
            SettingRow(
                title: L("Oturum açılınca Pusu çalışsın", "Open Pusu at login"),
                subtitle: L("Pusu oturum açıldığında menü çubuğunda çalışır.", "Pusu starts in the menu bar when you log in.")
            ) {
                SettingsToggle(title: L("Oturum açılınca Pusu çalışsın", "Open Pusu at login"), isOn: $settings.launchAtLogin)
            }
            Divider()
            SettingRow(
                title: L("Açıldığında hemen başlat", "Turn on when Pusu opens"),
                subtitle: L("Uygulama açılırken varsayılan süreyle Pusu'yu başlatır.", "Starts a session with the default duration when the app opens.")
            ) {
                SettingsToggle(title: L("Açıldığında hemen başlat", "Turn on when Pusu opens"), isOn: $settings.autoStartOnLaunch)
            }
        }
    }

    private var notificationsCard: some View {
        SettingsCard(
            title: L("Bildirimler", "Notifications"),
            subtitle: L("Süre dolduğunda, pil azaldığında ve uzak erişim modunda bilgi ver.", "Let you know when time is up, the battery is low, or remote access mode changes.")
        ) {
            SettingRow(
                title: L("Bildirim göster", "Show notifications"),
                subtitle: L("Sistem bildirimlerini kullan.", "Use system notifications.")
            ) {
                SettingsToggle(title: L("Bildirim göster", "Show notifications"), isOn: $settings.notificationsEnabled)
            }
            if settings.notificationsEnabled, ui.notificationsAuthorized == false {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "bell.slash")
                        .foregroundStyle(.orange)
                    Text(L("Sistem bildirim izni kapalı. Sistem Ayarları'ndan izin verin.", "Notifications are turned off for Pusu in System Settings."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Ayarları Aç", "Open Settings")) { openNotificationSettings() }
                        .buttonStyle(.link)
                }
            }
            Divider()
            SettingRow(
                title: L("Menü çubuğunda geri sayım", "Countdown in the menu bar"),
                subtitle: L("Menü çubuğunda kalan süreyi göster.", "Show the remaining time next to the icon.")
            ) {
                SettingsToggle(title: L("Menü çubuğunda geri sayım", "Countdown in the menu bar"), isOn: $settings.showCountdown)
            }
        }
    }

    private var hotkeyCard: some View {
        SettingsCard(
            title: L("Kısayol ve komutlar", "Shortcut and commands"),
            subtitle: L("Pusu'yu menüyü açmadan kontrol edin.", "Control Pusu without opening the menu.")
        ) {
            SettingRow(
                title: L("Simgeye tıklayınca aç/kapat", "Click the icon to turn on/off"),
                subtitle: L(
                    "Menü çubuğu simgesine tıklamak Pusu'yu açıp kapatır; menü sağ tıkla (veya Control-tık) açılır. Kapalıysa tıklama menüyü açar.",
                    "Clicking the menu bar icon turns Pusu on or off; right-click (or Control-click) opens the menu. When off, a click opens the menu."
                )
            ) {
                SettingsToggle(title: L("Simgeye tıklayınca aç/kapat", "Click the icon to turn on/off"), isOn: $settings.clickTogglesSession)
            }
            Divider()
            SettingRow(
                title: L("Global kısayol", "Global shortcut"),
                subtitle: L("Pusu'yu herhangi bir uygulamadan açıp kapatır.", "Turns Pusu on or off from any app.")
            ) {
                Picker("", selection: $settings.hotkeyPreset) {
                    ForEach(HotKeyPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            Divider()
            Text("pusu on 60\npusu on 1h30m\npusu off\npusu status\n\npusu://toggle\npusu://on?minutes=60")
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
        }
    }

    private var languageCard: some View {
        SettingsCard(
            title: L("Dil", "Language"),
            subtitle: L("Arayüz dili. Sistem dili seçiliyse macOS Türkçeyse Türkçe, değilse İngilizce kullanılır.", "Interface language. With System language, Pusu uses Turkish if macOS is in Turkish and English otherwise.")
        ) {
            SettingRow(title: L("Arayüz dili", "Interface language"), subtitle: nil) {
                Picker("", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
        }
    }

    private var updatesStatus: String {
        switch updates.state {
        case .checking:
            return L("Denetleniyor…", "Checking…")
        case .available(let update):
            return L("Pusu \(update.version) yayında", "Pusu \(update.version) is available")
        case .upToDate:
            return L("Güncel · \(CLI.version)", "Up to date · \(CLI.version)")
        case .failed:
            return L("Son denetim başarısız", "The last check failed")
        case .idle:
            if let last = settings.lastUpdateCheck {
                return L("Son denetim: \(TimeText.clock(last))", "Last checked: \(TimeText.clock(last))")
            }
            return L("Henüz denetlenmedi", "Not checked yet")
        }
    }

    private var updatesCard: some View {
        SettingsCard(
            title: L("Güncellemeler", "Updates"),
            subtitle: L(
                "Pusu yalnızca GitHub'dan en son sürüm numarasını okur; kimlik ya da kullanım verisi gönderilmez.",
                "Pusu only reads the latest version number from GitHub; no identifying or usage data is sent."
            )
        ) {
            SettingRow(
                title: L("Günde bir kez otomatik denetle", "Check automatically once a day"),
                subtitle: L("Kapalıysa Pusu yalnızca siz \"Şimdi Denetle\"ye bastığınızda bakar.", "When off, Pusu only checks when you click \"Check Now\".")
            ) {
                SettingsToggle(title: L("Günde bir kez otomatik denetle", "Check automatically once a day"), isOn: $settings.updateCheckEnabled)
            }
            Divider()
            HStack(spacing: 10) {
                Text(updatesStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if updates.available != nil {
                    Button(L("Ayrıntılar…", "Details…")) { actions.showUpdate() }
                }
                Button(L("Şimdi Denetle", "Check Now")) { actions.checkForUpdates() }
                    .disabled(updates.state == .checking)
            }
        }
    }

    private var aboutCard: some View {
        SettingsCard(
            title: "Pusu \(CLI.version)",
            subtitle: L("Mac'in uyanık kalmasını sağlayan menü çubuğu uygulaması.", "A menu bar app that keeps your Mac awake.")
        ) {
            Text(L(
                "IOKit assertion'ları ve pmset ile sistemin uyumasını engeller; kapak modu için isteğe bağlı yönetici yardımcısı kullanır. Açık kaynak, GPL-3.0.",
                "Uses IOKit assertions and pmset to keep the system awake, with an optional privileged helper for lid mode. Open source, GPL-3.0."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button(L("Pusu Hakkında", "About Pusu")) { actions.about() }
                Link(L("Kaynak kod", "Source code"), destination: PusuLinks.repository)
                Link(L("Hata bildir", "Report a bug"), destination: PusuLinks.issues)
                Spacer()
                Text("© 2026 Pusu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var filesCard: some View {
        SettingsCard(
            title: L("Dosyalar", "Files"),
            subtitle: nil
        ) {
            StatusLine(title: L("Uygulama", "App"), value: Bundle.main.bundlePath)
            StatusLine(title: L("Veri", "Data"), value: RuntimePaths.supportDirectory.path)
            StatusLine(title: L("Geçmiş", "History"), value: RuntimePaths.history.path)
            StatusLine(title: L("Yardımcı", "Helper"), value: HelperProtocol.installedBinaryPath)
            StatusLine(title: L("Yardımcı logu", "Helper log"), value: HelperProtocol.logPath)
            StatusLine(title: L("Giriş öğesi", "Login item"), value: LaunchAtLogin.plistURL.path)
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Components

struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    init(title: String, subtitle: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}

private struct SettingRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing

    init(title: String, subtitle: String?, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

private struct SettingsToggle: View {
    let title: String
    let isOn: Binding<Bool>

    var body: some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel(Text(title))
    }
}

private struct ModeRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let active: Bool
    let actionTitle: String
    var actionDisabled = false
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(title)
                    if active {
                        Text(L("AÇIK", "ON"))
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(actionTitle, action: action)
                .disabled(actionDisabled)
                .accessibilityLabel("\(title): \(actionTitle)")
        }
    }
}

private struct StatusLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

private struct WarningCard: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.08))
        )
    }
}

extension Notification.Name {
    static let pusuHelperChanged = Notification.Name("local.kan.pusu.helperChanged")
    static let pusuStateChanged = Notification.Name("local.kan.pusu.stateChanged")
}
