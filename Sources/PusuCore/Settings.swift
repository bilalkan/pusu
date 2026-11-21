import Foundation
import Combine

public enum HotKeyPreset: String, CaseIterable, Identifiable, Codable {
    case ctrlOptCmdA
    case ctrlOptCmdK
    case ctrlOptCmdSpace
    case optCmdA
    case off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ctrlOptCmdA: return "⌃⌥⌘A"
        case .ctrlOptCmdK: return "⌃⌥⌘K"
        case .ctrlOptCmdSpace: return "⌃⌥⌘Space"
        case .optCmdA: return "⌥⌘A"
        case .off: return L("Kapalı", "Off")
        }
    }

    public var keyCode: UInt32? {
        switch self {
        case .ctrlOptCmdA, .optCmdA: return 0        // A
        case .ctrlOptCmdK: return 40                 // K
        case .ctrlOptCmdSpace: return 49             // Space
        case .off: return nil
        }
    }

    /// Carbon modifier mask.
    public var modifiers: UInt32 {
        switch self {
        case .ctrlOptCmdA, .ctrlOptCmdK, .ctrlOptCmdSpace:
            return 0x1000 | 0x0800 | 0x0100          // control + option + command
        case .optCmdA:
            return 0x0800 | 0x0100                    // option + command
        case .off:
            return 0
        }
    }
}

public final class SettingsStore: ObservableObject {
    private enum Key: String {
        case keepDisplayAwake = "pusu.keepDisplayAwake"
        case keepSessionUnlocked = "pusu.keepSessionUnlocked"
        case batteryCutoffEnabled = "pusu.batteryCutoffEnabled"
        case batteryCutoffPercent = "pusu.batteryCutoffPercent"
        case lidBatteryFloorEnabled = "pusu.lidBatteryFloorEnabled"
        case lidBatteryFloorPercent = "pusu.lidBatteryFloorPercent"
        case defaultDuration = "pusu.defaultDuration"
        case launchAtLogin = "pusu.launchAtLogin"
        case autoStartOnLaunch = "pusu.autoStartOnLaunch"
        case notificationsEnabled = "pusu.notificationsEnabled"
        case showCountdown = "pusu.showCountdown"
        case remoteLockOnBlackout = "pusu.remoteLockOnBlackout"
        case remoteKeepsDisplayOn = "pusu.remoteKeepsDisplayOn"
        case clickTogglesSession = "pusu.clickTogglesSession"
        case updateCheckEnabled = "pusu.updateCheckEnabled"
        case updateCheckAsked = "pusu.updateCheckAsked"
        case lastUpdateCheck = "pusu.lastUpdateCheck"
        case notifiedUpdateVersion = "pusu.notifiedUpdateVersion"
        case hotkeyPreset = "pusu.hotkeyPreset"
        case fallbackSleepDisabledOriginal = "pusu.fallbackSleepDisabledOriginal"
        case fallbackSleepDisabledActive = "pusu.fallbackSleepDisabledActive"
    }

    private let defaults: UserDefaults
    public var onChange: (() -> Void)?

    @Published public var keepDisplayAwake: Bool {
        didSet { save(keepDisplayAwake, .keepDisplayAwake); onChange?() }
    }
    @Published public var keepSessionUnlocked: Bool {
        didSet { save(keepSessionUnlocked, .keepSessionUnlocked); onChange?() }
    }
    @Published public var batteryCutoffEnabled: Bool {
        didSet { save(batteryCutoffEnabled, .batteryCutoffEnabled); onChange?() }
    }
    @Published public var batteryCutoffPercent: Int {
        didSet { save(batteryCutoffPercent, .batteryCutoffPercent); onChange?() }
    }
    @Published public var lidBatteryFloorEnabled: Bool {
        didSet { save(lidBatteryFloorEnabled, .lidBatteryFloorEnabled); onChange?() }
    }
    @Published public var lidBatteryFloorPercent: Int {
        didSet { save(lidBatteryFloorPercent, .lidBatteryFloorPercent); onChange?() }
    }
    @Published public var defaultDuration: PusuDuration {
        didSet {
            save(defaultDuration.seconds ?? -1, .defaultDuration)
            onChange?()
        }
    }
    @Published public var launchAtLogin: Bool {
        didSet { save(launchAtLogin, .launchAtLogin); onChange?() }
    }
    @Published public var autoStartOnLaunch: Bool {
        didSet { save(autoStartOnLaunch, .autoStartOnLaunch); onChange?() }
    }
    @Published public var notificationsEnabled: Bool {
        didSet { save(notificationsEnabled, .notificationsEnabled); onChange?() }
    }
    @Published public var showCountdown: Bool {
        didSet { save(showCountdown, .showCountdown); onChange?() }
    }
    @Published public var remoteLockOnBlackout: Bool {
        didSet { save(remoteLockOnBlackout, .remoteLockOnBlackout); onChange?() }
    }
    /// Uzak erişimde ekran hiç uyutulmaz, yalnızca karartılır (parlaklık 0, siyah görüntü).
    /// Kapalıysa (varsayılan) ekran bağlantı gelene kadar uyur; Apple Ekran Paylaşımı ve Tern
    /// ekranı uyandırır. Diğer uzak erişim uygulamaları için açılır.
    @Published public var remoteKeepsDisplayOn: Bool {
        didSet { save(remoteKeepsDisplayOn, .remoteKeepsDisplayOn); onChange?() }
    }
    /// Menü çubuğu simgesine (sol) tıklamak Pusu'yu açıp kapatır; menü sağ tıkla açılır.
    /// Kapalıysa tıklama menüyü açar.
    @Published public var clickTogglesSession: Bool {
        didSet { save(clickTogglesSession, .clickTogglesSession); onChange?() }
    }
    /// Günde bir kez GitHub'dan yeni sürüm kontrolü. Varsayılan kapalı; kullanıcıya bir kez sorulur.
    @Published public var updateCheckEnabled: Bool {
        didSet {
            save(updateCheckEnabled, .updateCheckEnabled)
            updateCheckAsked = true
            onChange?()
        }
    }

    /// Güncelleme kontrolü için izin soruldu mu?
    public var updateCheckAsked: Bool {
        get { defaults.bool(forKey: Key.updateCheckAsked.rawValue) }
        set { defaults.set(newValue, forKey: Key.updateCheckAsked.rawValue) }
    }

    public var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheck.rawValue) as? Date }
        set { defaults.set(newValue, forKey: Key.lastUpdateCheck.rawValue) }
    }

    /// Bildirimi gösterilmiş son sürüm (aynı sürüm için tekrar bildirim gönderilmez).
    public var notifiedUpdateVersion: String? {
        get { defaults.string(forKey: Key.notifiedUpdateVersion.rawValue) }
        set { defaults.set(newValue, forKey: Key.notifiedUpdateVersion.rawValue) }
    }
    @Published public var hotkeyPreset: HotKeyPreset {
        didSet { save(hotkeyPreset.rawValue, .hotkeyPreset); onChange?() }
    }
    /// Arayüz dili. Seçim `Localization` üzerinden uygulama genelinde saklanır.
    @Published public var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            Localization.preference = language
            onChange?()
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        SettingsStore.migrateLegacyDefaultsIfNeeded(defaults)

        self.keepDisplayAwake = defaults.object(forKey: Key.keepDisplayAwake.rawValue) as? Bool ?? true
        self.keepSessionUnlocked = defaults.object(forKey: Key.keepSessionUnlocked.rawValue) as? Bool ?? false
        self.batteryCutoffEnabled = defaults.object(forKey: Key.batteryCutoffEnabled.rawValue) as? Bool ?? true
        self.batteryCutoffPercent = defaults.object(forKey: Key.batteryCutoffPercent.rawValue) as? Int ?? 10
        self.lidBatteryFloorEnabled = defaults.object(forKey: Key.lidBatteryFloorEnabled.rawValue) as? Bool ?? true
        self.lidBatteryFloorPercent = defaults.object(forKey: Key.lidBatteryFloorPercent.rawValue) as? Int ?? 20

        let storedDuration = defaults.object(forKey: Key.defaultDuration.rawValue) as? Double
        self.defaultDuration = (storedDuration ?? -1) > 0
            ? PusuDuration(seconds: storedDuration)
            : .indefinite

        self.launchAtLogin = defaults.object(forKey: Key.launchAtLogin.rawValue) as? Bool ?? false
        self.autoStartOnLaunch = defaults.object(forKey: Key.autoStartOnLaunch.rawValue) as? Bool ?? false
        self.notificationsEnabled = defaults.object(forKey: Key.notificationsEnabled.rawValue) as? Bool ?? true
        self.showCountdown = defaults.object(forKey: Key.showCountdown.rawValue) as? Bool ?? true
        self.remoteLockOnBlackout = defaults.object(forKey: Key.remoteLockOnBlackout.rawValue) as? Bool ?? true
        self.remoteKeepsDisplayOn = defaults.object(forKey: Key.remoteKeepsDisplayOn.rawValue) as? Bool ?? false
        self.clickTogglesSession = defaults.object(forKey: Key.clickTogglesSession.rawValue) as? Bool ?? true
        self.updateCheckEnabled = defaults.object(forKey: Key.updateCheckEnabled.rawValue) as? Bool ?? false

        let rawHotkey = defaults.string(forKey: Key.hotkeyPreset.rawValue)
        self.hotkeyPreset = rawHotkey.flatMap(HotKeyPreset.init(rawValue:)) ?? .ctrlOptCmdA
        self.language = Localization.preference
    }

    private func save(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    /// Awake (local.kan.awake) ayarlarını Pusu alan adına taşır.
    /// Yalnızca gerçek uygulama alanında çalışır; test suite'lerini etkilemez.
    public static func migrateLegacyDefaultsIfNeeded(_ defaults: UserDefaults) {
        guard defaults === UserDefaults.standard else { return }

        let legacyDomain = "local.kan.awake"
        guard let legacy = defaults.persistentDomain(forName: legacyDomain), !legacy.isEmpty else {
            return
        }

        let newDomain = Bundle.main.bundleIdentifier ?? "local.kan.pusu"
        var current = defaults.persistentDomain(forName: newDomain) ?? [:]

        for (oldKey, value) in legacy {
            let newKey: String
            if oldKey == "awake.startAwakeOnLaunch" {
                newKey = "pusu.autoStartOnLaunch"
            } else if oldKey.hasPrefix("awake.") {
                newKey = "pusu." + String(oldKey.dropFirst("awake.".count))
            } else {
                newKey = oldKey
            }
            if current[newKey] == nil {
                current[newKey] = value
            }
        }

        defaults.setPersistentDomain(current, forName: newDomain)
        defaults.removePersistentDomain(forName: legacyDomain)
    }

    // MARK: - Fallback lid state (used only when the privileged helper is absent)

    public var fallbackSleepDisabledOriginal: Bool? {
        get {
            guard defaults.object(forKey: Key.fallbackSleepDisabledOriginal.rawValue) != nil else { return nil }
            return defaults.bool(forKey: Key.fallbackSleepDisabledOriginal.rawValue)
        }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.fallbackSleepDisabledOriginal.rawValue)
            } else {
                defaults.removeObject(forKey: Key.fallbackSleepDisabledOriginal.rawValue)
            }
        }
    }

    public var fallbackSleepDisabledActive: Bool {
        get { defaults.bool(forKey: Key.fallbackSleepDisabledActive.rawValue) }
        set { defaults.set(newValue, forKey: Key.fallbackSleepDisabledActive.rawValue) }
    }
}
