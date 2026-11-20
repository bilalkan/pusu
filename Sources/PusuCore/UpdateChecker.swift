import Foundation

/// `1.0.3`, `v1.2` gibi sürüm numaralarını karşılaştırır. Yalnızca rakam ve noktadan
/// oluşan sürümler kabul edilir (ön sürüm ekleri olan etiketler yok sayılır).
public struct AppVersion: Comparable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 6, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part)
            else { return nil }
            numbers.append(value)
        }
        components = numbers
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// GitHub'da yayınlanmış daha yeni bir sürüm.
public struct AvailableUpdate: Equatable {
    public let version: String
    public let releaseURL: URL
}

/// İsteğe bağlı güncelleme kontrolü. Yalnızca kullanıcı izin verirse ve günde en fazla bir kez
/// GitHub'ın herkese açık "son sürüm" adresine bir istek gönderir; çerez, önbellek ya da
/// kimlik/kullanım verisi kullanılmaz.
public enum UpdateChecker {
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/bilalkan/pusu/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/bilalkan/pusu/releases/latest")!
    public static let releasePagePrefix = "https://github.com/bilalkan/pusu/releases/"
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    /// Kontrol zamanı geldi mi?
    public static func isDue(enabled: Bool?, lastCheck: Date?, now: Date = Date()) -> Bool {
        guard enabled == true else { return false }
        guard let lastCheck else { return true }
        // Saat geri alınmışsa (lastCheck gelecekte) de kontrol et.
        return now.timeIntervalSince(lastCheck) >= checkInterval || lastCheck > now
    }

    /// GitHub `releases/latest` yanıtını çözer. Taslak/ön sürüm ya da beklenmeyen bir alan
    /// varsa `nil` döner. Sürüm sayfası adresi yalnızca bu reponun sürüm sayfasıysa kullanılır.
    public static func parseLatestRelease(_ data: Data) -> AvailableUpdate? {
        guard data.count < 1_000_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let version = AppVersion(tag)
        else { return nil }
        if json["draft"] as? Bool == true || json["prerelease"] as? Bool == true { return nil }
        var url = releasesPage
        // Adres önce normalleştirilir (`..` gibi bölümler çözülür), sonra bu reponun sürüm
        // sayfası olduğu doğrulanır; değilse sabit sürüm sayfası kullanılır.
        if let raw = json["html_url"] as? String,
           let parsed = URL(string: raw)?.standardized,
           parsed.scheme == "https", parsed.host == "github.com",
           parsed.absoluteString.hasPrefix(releasePagePrefix) {
            url = parsed
        }
        return AvailableUpdate(version: version.description, releaseURL: url)
    }

    /// `latest` mevcut sürümden yeniyse onu döndürür.
    public static func newer(_ latest: AvailableUpdate?, than current: String) -> AvailableUpdate? {
        guard let latest, let new = AppVersion(latest.version), let old = AppVersion(current), old < new else {
            return nil
        }
        return latest
    }

    /// Ağ isteği. Sonuç ana kuyrukta değil, URLSession'ın kuyruğunda döner.
    public static func fetchLatest(completion: @escaping (Result<AvailableUpdate?, Error>) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)

        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Pusu-update-check", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else {
                completion(.success(nil))
                return
            }
            completion(.success(parseLatestRelease(data)))
        }.resume()
    }

    /// Uygulama Homebrew cask'ı ile mi kuruldu? Öyleyse güncelleme `brew upgrade` ile yapılmalı.
    public static func installedWithHomebrew(
        caskroomPaths: [String] = ["/opt/homebrew/Caskroom/pusu", "/usr/local/Caskroom/pusu"]
    ) -> Bool {
        caskroomPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    public static let homebrewUpgradeCommand = "brew update && brew upgrade --cask pusu"
}
