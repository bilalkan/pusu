import Foundation

/// IOKit güç assertion'ları. Gerçek uygulama `PowerAssertions`, testler sahte bir uygulama kullanır.
public protocol PowerAsserting: AnyObject {
    var isSystemHeld: Bool { get }
    var isDisplayHeld: Bool { get }
    var isUserActivityHeld: Bool { get }

    @discardableResult
    func acquire(system: Bool, display: Bool, reason: String) -> Bool
    @discardableResult
    func declareUserActivity(reason: String) -> Bool
    func releaseUserActivity()
    func releaseAll()
}

public extension PowerAsserting {
    @discardableResult
    func declareUserActivity() -> Bool {
        declareUserActivity(reason: "Pusu keeps the session unlocked")
    }
}

/// Kapak modu (`pmset disablesleep`). Yardımcı varsa onun üzerinden, yoksa yönetici parolasıyla.
public protocol LidControlling: AnyObject {
    /// Güncel root yardımcısı yanıt veriyor mu? (Kapak modunu açmak için gerekir.)
    var helperAvailable: Bool { get }
    /// Herhangi bir sürüm yardımcı yanıt veriyor mu? (Kapatmak/geri yüklemek için yeterli.)
    var helperResponding: Bool { get }
    /// Yardımcı yokken SleepDisabled'ı Pusu mu değiştirdi?
    var usesFallback: Bool { get }

    func helperStatus() -> HelperStatus?
    func sleepDisabled(timeout: TimeInterval) -> Bool?
    func setEnabled(_ enabled: Bool, allowPrompt: Bool) throws
}

public extension LidControlling {
    func sleepDisabled() -> Bool? {
        sleepDisabled(timeout: 15)
    }
}

/// VNC/uzak erişim için ekran kilidi, karartma ve servis durumu.
public protocol RemoteControlling: AnyObject {
    @discardableResult
    func lockScreen() -> Bool
    func isScreenLocked() -> Bool
    @discardableResult
    func sleepDisplay() -> Bool
    @discardableResult
    func wakeDisplay() -> Bool
    func screenSharingState(timeout: TimeInterval) -> ScreenSharingState
    func remoteManagementRunning(timeout: TimeInterval) -> Bool
}

public extension RemoteControlling {
    func screenSharingState() -> ScreenSharingState {
        screenSharingState(timeout: 15)
    }

    func remoteManagementRunning() -> Bool {
        remoteManagementRunning(timeout: 15)
    }
}
