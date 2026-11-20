import Foundation

/// Arayüz dili. `system` macOS dil tercihini izler: Türkçe ise Türkçe, değilse İngilizce.
public enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system
    case turkish = "tr"
    case english = "en"

    public var id: String { rawValue }

    /// Dil seçicide her seçenek kendi dilinde gösterilir.
    public var title: String {
        switch self {
        case .system: return L("Sistem dili", "System language")
        case .turkish: return "Türkçe"
        case .english: return "English"
        }
    }
}

/// Pusu'nun iki dilli metin altyapısı.
///
/// Metinler kaynakta `L("Türkçe", "English")` biçiminde yan yana yazılır; böylece bir
/// çeviri hiçbir zaman eksik kalmaz ve PusuCore, CLI, yardımcı ve testler aynı yolu kullanır.
public enum Localization {
    public static let defaultsKey = "pusu.language"

    private static let lock = NSLock()
    private static var cachedPreference: AppLanguage?
    private static var forcedLanguage: AppLanguage?

    /// Kullanıcının seçimi (UserDefaults). Varsayılan: sistem dili.
    public static var preference: AppLanguage {
        get {
            lock.lock(); defer { lock.unlock() }
            if let cachedPreference { return cachedPreference }
            // `pusu` komutu sembolik bağ üzerinden çalışınca standart alan uygulamanınki olmaz;
            // seçimi uygulamanın ayar alanından da oku.
            let raw = UserDefaults.standard.string(forKey: defaultsKey)
                ?? UserDefaults(suiteName: "local.kan.pusu")?.string(forKey: defaultsKey)
            let value = raw.flatMap(AppLanguage.init(rawValue:)) ?? .system
            cachedPreference = value
            return value
        }
        set {
            lock.lock()
            cachedPreference = newValue
            lock.unlock()
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            } else {
                UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            }
        }
    }

    /// Testler ve komut satırı için dili sabitler; `nil` normal davranışa döner.
    public static func force(_ language: AppLanguage?) {
        lock.lock(); defer { lock.unlock() }
        forcedLanguage = language
    }

    /// Şu an kullanılan somut dil (`.turkish` veya `.english`).
    public static var resolved: AppLanguage {
        lock.lock()
        let forced = forcedLanguage
        lock.unlock()
        if let forced, forced != .system { return forced }
        switch preference {
        case .turkish: return .turkish
        case .english: return .english
        case .system: return systemLanguage
        }
    }

    public static var isTurkish: Bool { resolved == .turkish }

    /// Tarih/sayı biçimlendirme için arayüz diliyle uyumlu yerel ayar.
    public static var locale: Locale {
        isTurkish ? Locale(identifier: "tr_TR") : Locale(identifier: "en_US")
    }

    /// Yüzde gösterimi: Türkçede `%20`, İngilizcede `20%`.
    public static func percent(_ value: Int) -> String {
        isTurkish ? "%\(value)" : "\(value)%"
    }

    public static var systemLanguage: AppLanguage {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("tr") ? .turkish : .english
    }
}

/// İki dilli metin: arayüz dili Türkçeyse ilkini, değilse ikincisini döndürür.
@inline(__always)
public func L(_ turkish: String, _ english: String) -> String {
    Localization.isTurkish ? turkish : english
}
