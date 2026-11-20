import Foundation
import Darwin
import CoreGraphics

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

public final class RemoteController: RemoteControlling {
    public init() {}

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
