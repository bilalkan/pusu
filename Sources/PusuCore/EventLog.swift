import Foundation

/// Olay kaydı yazan nesne. Testler sahte bir kaydedici verir; `nil` verilirse hiçbir şey yazılmaz.
public protocol EventRecording: AnyObject {
    func record(_ message: String)
}

/// Kısa süreli olay günlüğü: "ne zaman ne oldu?" sorusunu sonradan yanıtlamak için.
///
/// Yalnızca bu Mac'te, kullanıcının Application Support klasöründe (`events.log`, 0600) tutulur;
/// hiçbir yere gönderilmez. Son `maxAge` süresindeki en fazla `maxEntries` satır saklanır.
/// Satırlar kullanıcı verisi içermez: oturum, kapak, uzak erişim, ekran ve uyku olayları.
public final class EventLog: EventRecording {
    public static let shared = EventLog()

    public static let maxAge: TimeInterval = 3 * 24 * 60 * 60
    public static let maxEntries = 1_000
    /// Bu kadar yazmada bir eski satırlar budanır.
    static let pruneEvery = 50
    static let maxMessageLength = 300

    public let url: URL
    private let now: () -> Date
    private let lock = NSLock()
    private var writesSincePrune = 0

    public init(url: URL = RuntimePaths.events, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.now = now
    }

    // MARK: - Writing

    public func record(_ message: String) {
        let line = Self.line(for: message, at: now())
        lock.lock()
        defer { lock.unlock() }
        append(line + "\n")
        writesSincePrune += 1
        if writesSincePrune >= Self.pruneEvery {
            pruneLocked()
        }
    }

    /// Eski satırları hemen buda (uygulama açılışında çağrılır).
    public func prune() {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked()
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
        writesSincePrune = 0
    }

    // MARK: - Reading

    /// Günlükteki satırlar, eskiden yeniye.
    public func lines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return linesLocked()
    }

    private func linesLocked() -> [String] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    public func tail(_ count: Int) -> [String] {
        Array(lines().suffix(max(0, count)))
    }

    // MARK: - Format

    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }()

    /// `2026-11-21 12:03:41 +0300  VNC mode on (locked: yes, display off: yes)`
    public static func line(for message: String, at date: Date) -> String {
        "\(formatter.string(from: date))  \(sanitize(message))"
    }

    /// Satırın tarihini çözer; biçim bozuksa `nil`.
    public static func date(ofLine line: String) -> Date? {
        // Tarih bölümü sabit uzunlukta: "yyyy-MM-dd HH:mm:ss +ZZZZ" = 25 karakter.
        guard line.count >= 25 else { return nil }
        return formatter.date(from: String(line.prefix(25)))
    }

    /// Satır sonu ve kontrol karakterlerini atar, uzunluğu sınırlar: bir mesaj günlüğe sahte
    /// satır ekleyemez.
    static func sanitize(_ message: String) -> String {
        let cleaned = String(String.UnicodeScalarView(message.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        }))
        if cleaned.count > maxMessageLength {
            return String(cleaned.prefix(maxMessageLength)) + "…"
        }
        return cleaned
    }

    /// Saklanacak satırlar: `maxAge`'den yeni ve en fazla `maxEntries` tane. Tarihi okunamayan
    /// satırlar atılır.
    public static func retained(_ lines: [String], now: Date) -> [String] {
        let cutoff = now.addingTimeInterval(-maxAge)
        let fresh = lines.filter { line in
            guard let date = date(ofLine: line) else { return false }
            return date >= cutoff
        }
        return Array(fresh.suffix(maxEntries))
    }

    // MARK: - Private

    private func append(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Sembolik bağı izleme (O_NOFOLLOW): günlük başka bir dosyaya yönlendirilemesin.
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        // Dosya daha önce başka izinlerle oluşturulduysa da yalnızca kullanıcıya açık olsun.
        fchmod(descriptor, 0o600)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try? handle.write(contentsOf: data)
    }

    private func pruneLocked() {
        writesSincePrune = 0
        let current = linesLocked()
        let kept = Self.retained(current, now: now())
        guard kept.count != current.count else { return }
        let text = kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return }
        if (try? data.write(to: url, options: .atomic)) != nil {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
