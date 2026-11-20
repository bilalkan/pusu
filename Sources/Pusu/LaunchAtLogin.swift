import Foundation
import PusuCore

enum LaunchAtLogin {
    static let label = "local.kan.pusu.login"
    static let legacyLabel = "local.kan.awake.login"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var legacyPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist")
    }

    static func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Eski Awake giriş öğesini kaldırır; yeni Pusu giriş öğesi sync() ile yazılır.
    static func migrateLegacy() {
        guard FileManager.default.fileExists(atPath: legacyPlistURL.path) else { return }
        try? FileManager.default.removeItem(at: legacyPlistURL)
        _ = Shell.run(
            "/bin/launchctl",
            ["bootout", "gui/\(getuid())/\(legacyLabel)"],
            timeout: 5
        )
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            let directory = plistURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua",
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            try data.write(to: plistURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: plistURL.path
            )
        } else {
            try? FileManager.default.removeItem(at: plistURL)
            _ = Shell.run(
                "/bin/launchctl",
                ["bootout", "gui/\(getuid())/\(label)"],
                timeout: 5
            )
        }
    }

    /// Uygulama geçici bir yerden (indirilen .dmg, App Translocation, İndirilenler) açıldıysa
    /// giriş öğesini oraya yönlendirmeyelim.
    static var bundleIsInStableLocation: Bool {
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") || path.hasPrefix("/private/var/folders/") {
            return false
        }
        return path.hasPrefix("/Applications/") || path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/")
    }

    static func sync(_ enabled: Bool) {
        do {
            if enabled, isEnabled(), !bundleIsInStableLocation {
                NSLog("Pusu: login item kept; app is running from a temporary location")
                return
            }
            if enabled {
                // Rewrite every launch so the path follows the installed bundle
                // (a development build later moved to /Applications).
                try setEnabled(true)
            } else if isEnabled() {
                try setEnabled(false)
            }
        } catch {
            NSLog("Pusu launch-at-login error: \(error.localizedDescription)")
        }
    }
}
