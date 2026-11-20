import Foundation

/// Yardımcının, kendisini kuran uygulamanın hâlâ yerinde olup olmadığını izlemesi.
///
/// Uygulama kaldırıldığında (Homebrew, Çöp Sepeti, `uninstall.sh`) geride root servisi
/// kalmasın diye yardımcı, uygulama paketi belirli bir süre boyunca kesintisiz yok
/// olduğunda kendini kaldırır. Süre, Homebrew güncellemesi gibi kısa boşlukları tolere eder.
public struct AppPresenceTracker {
    /// Uygulama bu kadar süre kesintisiz yoksa yardımcı kendini kaldırır.
    public static let defaultGracePeriod: TimeInterval = 15 * 60

    public let gracePeriod: TimeInterval
    public private(set) var missingSince: Date?

    public init(gracePeriod: TimeInterval = AppPresenceTracker.defaultGracePeriod) {
        self.gracePeriod = gracePeriod
    }

    /// Yeni bir gözlem kaydeder. `true` dönerse yardımcı kendini kaldırmalıdır.
    public mutating func observe(appExists: Bool, at now: Date = Date()) -> Bool {
        guard !appExists else {
            missingSince = nil
            return false
        }
        let since = missingSince ?? now
        missingSince = since
        return now.timeIntervalSince(since) >= gracePeriod
    }

    /// Kurulumda yardımcıya verilen uygulama yolu geçerli mi? Mutlak, `.app` ile biten,
    /// kontrol karakteri içermeyen bir yol olmalı.
    public static func isValidBundlePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.hasSuffix(".app"), path.count < 1024 else { return false }
        return !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Yardımcının izleyebileceği kalıcı bir konum mu? Disk görüntüleri, App Translocation,
    /// geçici klasörler ve gizlilik korumalı kullanıcı klasörleri (Masaüstü, Belgeler,
    /// İndirilenler; root süreç bunları göremeyebilir) kabul edilmez.
    public static func isStableBundleLocation(
        _ path: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> Bool {
        guard isValidBundlePath(path) else { return false }
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") || path.hasPrefix("/private/var/folders/") {
            return false
        }
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    /// Paketin gerçekten var olduğunu (yalnızca boş klasör değil) kontrol eder.
    public static func bundleExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("Contents/Info.plist"))
    }
}
