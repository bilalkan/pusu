import Foundation
import Darwin
import CoreGraphics
import IOKit.pwr_mgt
import PusuVirtualDisplay

public enum ScreenSharingState: String {
    case running
    case stopped
    case unknown

    public var label: String {
        switch self {
        case .running: return L("Ekran Paylaşımı açık", "Screen Sharing is on")
        case .stopped: return L("Ekran Paylaşımı kapalı", "Screen Sharing is off")
        case .unknown: return L("Durum bilinmiyor", "Status unknown")
        }
    }
}

/// Dahili ekran parlaklığı (DisplayServices). Desteklemeyen ekranlarda `nil`/`false` döner.
enum DisplayBrightness {
    private typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_LAZY
    )
    private static let getter: GetFunction? = handle
        .flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: GetFunction.self) }
    private static let setter: SetFunction? = handle
        .flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: SetFunction.self) }

    static func get(_ display: CGDirectDisplayID) -> Float? {
        guard let getter else { return nil }
        var value: Float = -1
        guard getter(display, &value) == 0, (0...1).contains(value) else { return nil }
        return value
    }

    static func set(_ display: CGDirectDisplayID, _ value: Float) -> Bool {
        guard let setter else { return false }
        return setter(display, min(max(value, 0), 1)) == 0
    }
}

/// Klavye arka ışığı (CoreBrightness). Desteklemeyen Mac'lerde `nil`/`false` döner.
enum KeyboardBacklight {
    private typealias GetFunction = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetFunction = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    private typealias TemporarySetFunction = @convention(c) (AnyObject, Selector, Float, Int32, Bool, UInt64) -> Bool

    private static let client: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type
        else { return nil }
        return type.init()
    }()

    private static let idsSelector = NSSelectorFromString("copyKeyboardBacklightIDs")
    private static let getSelector = NSSelectorFromString("brightnessForKeyboard:")
    private static let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")
    private static let temporarySetSelector = NSSelectorFromString("setBrightness:fadeSpeed:commit:forKeyboard:")

    /// Özel bir sınıf: bir macOS güncellemesinde yöntemin imzası değişirse yanlış tiplerle
    /// çağırmak tanımsız davranıştır. Bu yüzden her yöntem, çağrılmadan önce Objective-C tip
    /// kodu beklenenle (bu Mac'te doğrulanan) eşleşiyorsa kullanılır; eşleşmezse klavye
    /// ışığına hiç dokunulmaz.
    static func implementation(_ selector: Selector, expecting encoding: String) -> IMP? {
        guard let client, let method = class_getInstanceMethod(type(of: client), selector),
              let raw = method_getTypeEncoding(method),
              strippingOffsets(String(cString: raw)) == encoding
        else { return nil }
        return method_getImplementation(method)
    }

    /// "B36@0:8f16i20B24Q28" → "B@:fiBQ" (yalnızca tipler; kaydırmalar mimariye göre değişir).
    static func strippingOffsets(_ encoding: String) -> String {
        String(encoding.filter { !$0.isNumber })
    }

    private static var keyboardID: UInt64? {
        guard let client, implementation(idsSelector, expecting: "@@:") != nil,
              let ids = client.perform(idsSelector)?.takeRetainedValue() as? [NSNumber]
        else { return nil }
        return ids.first?.uint64Value
    }

    static func get() -> Float? {
        guard let client, let id = keyboardID,
              let imp = implementation(getSelector, expecting: "f@:Q")
        else { return nil }
        let value = unsafeBitCast(imp, to: GetFunction.self)(client, getSelector, id)
        return (0...1).contains(value) ? value : nil
    }

    /// Klavye ışığını geçici olarak ayarlar: kullanıcının kalıcı ayarı (Denetim Merkezi'ndeki
    /// değer) değişmez. Bu yöntem yoksa kalıcı yönteme düşer.
    @discardableResult
    static func set(_ value: Float) -> Bool {
        guard let client, let id = keyboardID else { return false }
        let clamped = min(max(value, 0), 1)
        if let imp = implementation(temporarySetSelector, expecting: "B@:fiBQ") {
            return unsafeBitCast(imp, to: TemporarySetFunction.self)(client, temporarySetSelector, clamped, 0, false, id)
        }
        guard let imp = implementation(setSelector, expecting: "B@:fQ") else { return false }
        return unsafeBitCast(imp, to: SetFunction.self)(client, setSelector, clamped, id)
    }
}

/// Klavye ışığını karartma ve geri yükleme kuralları. Işık geçici olarak 0'a çekilince macOS onu
/// "bastırılmış" sayar; otomatik parlaklık da tuşa basmak da yeniden yakmaz, yalnızca sıfırdan büyük
/// bir değer yakar. Bu yüzden 0 hiçbir zaman "geri yüklenmez".
public enum KeyboardLightPolicy {
    static let off: Float = 0.001

    /// Işık zaten kapalıysa (ör. aydınlık odada otomatik parlaklık) ona dokunulmaz.
    public static func shouldDarken(saved: Float) -> Bool { saved > off }

    /// Karanlık modda ışık yandığında (otomatik parlaklık ya da tuş) geri yüklenecek değer.
    public static func savedAfterLighting(saved: Float, current: Float) -> Float {
        saved > off ? saved : current
    }

    /// Karartma bitince ayarlanacak değer; `nil` ise ışığa dokunulmaz.
    public static func restoreValue(saved: Float?) -> Float? {
        guard let saved, saved > off else { return nil }
        return saved
    }
}

public final class RemoteController: RemoteControlling {

    /// Locks the current console session through the same private entry point
    /// used by the system's lock-screen UI.
    @discardableResult
    public func lockScreen() -> Bool {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/login.framework/Versions/A/login",
            RTLD_LAZY
        ) else { return false }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else { return false }
        typealias LockFunction = @convention(c) () -> Int32
        let function = unsafeBitCast(symbol, to: LockFunction.self)
        _ = function()

        for _ in 0..<12 {
            if isScreenLocked() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    public func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    @discardableResult
    public func sleepDisplay() -> Bool {
        Shell.run("/usr/bin/pmset", ["displaysleepnow"]).succeeded
    }

    @discardableResult
    public func wakeDisplay() -> Bool {
        Shell.run("/usr/bin/caffeinate", ["-u", "-t", "1"]).succeeded
    }

    // MARK: - Paneli karartma

    /// Karartmadan önceki parlaklıklar; uygulama karartma sırasında çökerse bir sonraki
    /// açılışta geri yüklenebilsin diye ayrıca diske de yazılır.
    private var savedBrightness: [CGDirectDisplayID: Float] = [:]
    private var darkActive = false
    private var virtualDisplay: PusuVirtualDisplay?
    private let defaults: UserDefaults
    static let savedBrightnessKey = "pusu.savedPanelBrightness"
    static let savedKeyboardKey = "pusu.savedKeyboardBrightness"
    private var savedKeyboard: Float?
    private var rememberedBrightness: [CGDirectDisplayID: Float] = [:]
    private var rememberedKeyboard: Float?

    public func rememberPanelLevels() {
        rememberedBrightness = [:]
        for display in Self.onlineDisplays() where display != virtualDisplay?.displayID {
            if let value = DisplayBrightness.get(display) { rememberedBrightness[display] = value }
        }
        rememberedKeyboard = KeyboardBacklight.get()
    }

    public func forgetPanelLevels() {
        rememberedBrightness = [:]
        rememberedKeyboard = nil
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    @discardableResult
    public func darkenPanel() -> Bool {
        // Uyuyan ekran "aktif" sayılmaz ama parlaklığı ayarlanabilir: uyanmadan önce karartmak
        // için çevrimiçi ekranlar kullanılır.
        let displays = Self.onlineDisplays().filter { $0 != virtualDisplay?.displayID }
        guard !displays.isEmpty else { return false }
        if !darkActive {
            savedBrightness = [:]
            for display in displays {
                if let value = rememberedBrightness[display] ?? DisplayBrightness.get(display) {
                    savedBrightness[display] = value
                }
            }
            persistSavedBrightness()
            savedKeyboard = rememberedKeyboard ?? KeyboardBacklight.get()
            if let savedKeyboard {
                defaults.set(Double(savedKeyboard), forKey: Self.savedKeyboardKey)
                defaults.synchronize()
            }
        }
        if let savedKeyboard, KeyboardLightPolicy.shouldDarken(saved: savedKeyboard) { KeyboardBacklight.set(0) }
        darkActive = true
        // Siyah renk eğrisi yalnızca fiziksel panele giden görüntüyü etkiler; ekran görüntüsü ve
        // uzak paylaşım normal kalır. Süreç kapanınca macOS bunu kendiliğinden geri alır. Yalnızca
        // açık ekranlara uygulanabilir: ekran uyuyorsa `false` döner, uyanınca yeniden denenir.
        var allDark = true
        for display in displays {
            if savedBrightness[display] != nil { _ = DisplayBrightness.set(display, 0) }
            let isActive = CGDisplayIsActive(display) != 0 && CGDisplayIsAsleep(display) == 0
            if !isActive || CGSetDisplayTransferByFormula(display, 0, 0, 1, 0, 0, 1, 0, 0, 1) != .success {
                allDark = false
            }
        }
        return allDark
    }

    public func maintainDarkPanel() {
        guard darkActive else { return }
        // Klavye ışığı otomatik ayar ya da tuşla yanarsa yeniden kapatılır.
        if let saved = savedKeyboard, let value = KeyboardBacklight.get(), value > KeyboardLightPolicy.off {
            let updated = KeyboardLightPolicy.savedAfterLighting(saved: saved, current: value)
            if updated != saved {
                savedKeyboard = updated
                defaults.set(Double(updated), forKey: Self.savedKeyboardKey)
            }
            KeyboardBacklight.set(0)
        }
        for display in Self.activeDisplays() where display != virtualDisplay?.displayID {
            if savedBrightness[display] == nil {
                // Karartma sırasında bağlanan ekran.
                if let value = DisplayBrightness.get(display) {
                    savedBrightness[display] = value
                    persistSavedBrightness()
                }
            }
            if savedBrightness[display] != nil, let value = DisplayBrightness.get(display), value > 0.001 {
                _ = DisplayBrightness.set(display, 0)
            }
            if !Self.gammaIsBlack(display) {
                _ = CGSetDisplayTransferByFormula(display, 0, 0, 1, 0, 0, 1, 0, 0, 1)
            }
        }
    }

    static func gammaIsBlack(_ display: CGDirectDisplayID) -> Bool {
        var redMin: CGGammaValue = 0, redMax: CGGammaValue = 0, redGamma: CGGammaValue = 0
        var greenMin: CGGammaValue = 0, greenMax: CGGammaValue = 0, greenGamma: CGGammaValue = 0
        var blueMin: CGGammaValue = 0, blueMax: CGGammaValue = 0, blueGamma: CGGammaValue = 0
        guard CGGetDisplayTransferByFormula(
            display, &redMin, &redMax, &redGamma, &greenMin, &greenMax, &greenGamma, &blueMin, &blueMax, &blueGamma
        ) == .success else { return false }
        return max(redMax, greenMax, blueMax) < 0.001
    }

    // MARK: - İzlenme

    private typealias WatcherFunction = @convention(c) () -> Bool
    private static let watcherFunction: WatcherFunction? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(handle, "SLSIsScreenWatcherPresent")
        else { return nil }
        return unsafeBitCast(symbol, to: WatcherFunction.self)
    }()

    /// macOS'un "ekranınız izleniyor" bilgisi. Bulunamazsa `false`.
    public func screenIsBeingWatched() -> Bool {
        Self.watcherFunction?() ?? false
    }

    // MARK: - Mac başındaki kişi

    public func lastLocalInputDate() -> Date? {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let dictionary = byProcess?.takeRetainedValue() as? [AnyHashable: [[String: Any]]]
        else { return nil }
        var latest: Date?
        for assertions in dictionary.values {
            for assertion in assertions {
                guard assertion["AssertType"] as? String == "UserIsActive",
                      let name = assertion["AssertName"] as? String,
                      Self.isLocalInputAssertion(name)
                else { continue }
                let date = (assertion["AssertTimeoutUpdateTime"] as? Date) ?? (assertion["AssertStartWhen"] as? Date)
                if let date, date > (latest ?? .distantPast) { latest = date }
            }
        }
        return latest
    }

    /// WindowServer, bir HID aygıtı kullanılınca `…queue.tickle serviceID:… product:<aygıt>`
    /// adlı bir "kullanıcı etkin" kaydı tutar. Uzaktan (bir süreç tarafından) gönderilen olaylar
    /// `…queue.tickle.nxevent … process:<ad>` olarak, aygıtsız olaylar `product:(null)` olarak
    /// görünür; bunlar sayılmaz.
    public static func isLocalInputAssertion(_ name: String) -> Bool {
        name.hasPrefix("com.apple.iohideventsystem.queue.tickle serviceID:")
            && !name.contains(".nxevent")
            && name.contains("product:")
            && !name.contains("product:(null)")
    }

    // MARK: - Sanal ekran

    public var virtualDisplayActive: Bool { virtualDisplay != nil }

    @discardableResult
    public func showVirtualDisplay() -> Bool {
        if virtualDisplay != nil { return true }
        virtualDisplay = PusuVirtualDisplay(width: 1920, height: 1200, name: "Pusu")
        guard let id = virtualDisplay?.displayID else { return false }
        makeMainDisplay(id, attempt: 0)
        return true
    }

    /// Kilit ekranı (parola kutusu) ana ekranda çıkar. Kapak kapalıyken macOS ana ekran olarak
    /// kapalı dahili ekranı tutabilir; sanal ekranı ana ekran yap ki uzak bağlantı kilidi görsün.
    /// Sanal ekran çevrimiçi olana kadar kısa aralıklarla dener. Ayar yalnızca bu uygulama
    /// içindir; Pusu kapanınca macOS geri alır.
    private func makeMainDisplay(_ id: CGDirectDisplayID, attempt: Int) {
        guard virtualDisplay?.displayID == id else { return }
        if CGDisplayIsMain(id) != 0 { return }
        var config: CGDisplayConfigRef?
        if CGDisplayIsOnline(id) != 0, CGBeginDisplayConfiguration(&config) == .success, let config {
            if CGConfigureDisplayOrigin(config, id, 0, 0) == .success,
               CGCompleteDisplayConfiguration(config, .forAppOnly) == .success {
                return
            }
            CGCancelDisplayConfiguration(config)
        }
        guard attempt < 20 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.makeMainDisplay(id, attempt: attempt + 1)
        }
    }

    public func hideVirtualDisplay() {
        // Nesne bırakılınca macOS ekranı kaldırır.
        virtualDisplay = nil
    }

    public func restorePanel() {
        CGDisplayRestoreColorSyncSettings()
        for (display, value) in savedBrightness {
            _ = DisplayBrightness.set(display, value)
        }
        savedBrightness = [:]
        if let value = KeyboardLightPolicy.restoreValue(saved: savedKeyboard) { KeyboardBacklight.set(value) }
        savedKeyboard = nil
        darkActive = false
        defaults.removeObject(forKey: Self.savedBrightnessKey)
        defaults.removeObject(forKey: Self.savedKeyboardKey)
    }

    /// Önceki çalıştırma karartma sırasında beklenmedik şekilde kapandıysa parlaklığı geri yükler.
    /// (Renk eğrisini macOS süreç kapanınca zaten geri alır.)
    @discardableResult
    public func restoreAfterCrashIfNeeded() -> Bool {
        if let keyboard = defaults.object(forKey: Self.savedKeyboardKey) as? Double, (0...1).contains(keyboard) {
            if let value = KeyboardLightPolicy.restoreValue(saved: Float(keyboard)) { KeyboardBacklight.set(value) }
            defaults.removeObject(forKey: Self.savedKeyboardKey)
        }
        guard let stored = defaults.dictionary(forKey: Self.savedBrightnessKey) as? [String: Double] else {
            return false
        }
        for (key, value) in stored {
            if let display = CGDirectDisplayID(key), (0...1).contains(value) {
                _ = DisplayBrightness.set(display, Float(value))
            }
        }
        defaults.removeObject(forKey: Self.savedBrightnessKey)
        return true
    }

    private func persistSavedBrightness() {
        let stored = Dictionary(uniqueKeysWithValues: savedBrightness.map { (String($0.key), Double($0.value)) })
        defaults.set(stored, forKey: Self.savedBrightnessKey)
        // Ekran karartılmadan önce diske yazılsın: süreç hemen ardından öldürülürse de bir
        // sonraki açılışta parlaklık geri yüklenebilsin.
        defaults.synchronize()
    }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }

    static func activeDisplays() -> [CGDirectDisplayID] {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }

    public func screenSharingState(timeout: TimeInterval) -> ScreenSharingState {
        let result = Shell.run("/bin/launchctl", ["print", "system/com.apple.screensharing"], timeout: timeout)
        guard result.succeeded else { return .unknown }
        if result.stdout.contains("state = running") || result.stdout.contains("active count = 1") {
            return .running
        }
        if result.stdout.contains("state = not running") {
            return .stopped
        }
        return .unknown
    }

    public func remoteManagementRunning(timeout: TimeInterval) -> Bool {
        Shell.run("/usr/bin/pgrep", ["-x", "ARDAgent"], timeout: timeout).succeeded
    }
}
