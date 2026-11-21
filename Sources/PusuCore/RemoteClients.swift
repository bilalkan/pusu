import Foundation

/// Uzaktan bağlı bir istemci olup olmadığını bildirir. Uzak erişim modunda ekran, bağlantı
/// yokken uyur (en az pil); bağlantı gelince karanlık olarak uyanır.
public protocol RemoteClientMonitoring: AnyObject {
    var isConnected: Bool { get }
    /// Her yeni bağlantıda (`true`) ve her ayrılmada (`false`) ana kuyrukta çağrılır.
    var onClientEvent: ((Bool) -> Void)? { get set }
    func start()
    func stop()
}

/// Tern günlüğündeki tek bir olay.
public enum TernLogEvent: Equatable {
    case attached(Int)
    case detached(Int)
    /// Tern servisi yeniden başladı; önceki bağlantılar geçersiz.
    case daemonStarted
}

/// Tern'in kendi günlük dosyasını (`~/Library/Logs/Tern/tern-daemon.log`) izler.
///
/// Tern, telefondan bağlanıldığında oraya `daemon client attached id=… kind=Remote`, bağlantı
/// kapanınca `… detached …` yazar. Pusu dosyayı yalnızca okur; ağa ya da Tern'e dokunmaz.
/// Tern kurulu değilse ya da günlük biçimi değişirse sessizce hiçbir şey yapmaz (ekran uykuda
/// kalır, Apple Ekran Paylaşımı yine çalışır).
public final class TernClientWatcher: RemoteClientMonitoring {
    /// Bu Mac'te Tern kurulu ve kullanılmış mı? (Uzak erişim için Ekran Paylaşımı şart değil.)
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: defaultLogURL.path)
    }

    public static var defaultLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Tern/tern-daemon.log")
    }

    /// Başlarken geçmişten okunacak en fazla bayt (açık bağlantıları bulmak için).
    static let backlogBytes: UInt64 = 256 * 1024

    public var onClientEvent: ((Bool) -> Void)?
    /// Tanılama arka planda okuyabildiği için kilitli.
    public var isConnected: Bool {
        clientsLock.lock()
        defer { clientsLock.unlock() }
        return !clientsStorage.isEmpty
    }
    private let clientsLock = NSLock()

    private let url: URL
    private let pollInterval: TimeInterval
    private var clientsStorage = Set<Int>()
    private var clients: Set<Int> {
        get { clientsLock.lock(); defer { clientsLock.unlock() }; return clientsStorage }
        set { clientsLock.lock(); clientsStorage = newValue; clientsLock.unlock() }
    }
    private var offset: UInt64 = 0
    private var fileID: UInt64?
    private var partialLine = ""
    private var timer: Timer?

    public init(url: URL = TernClientWatcher.defaultLogURL, pollInterval: TimeInterval = 1) {
        self.url = url
        self.pollInterval = pollInterval
    }

    public func start() {
        guard timer == nil else { return }
        clients = []
        partialLine = ""
        // Son bölümü okuyarak şu an açık bağlantıları bul, sonra dosyanın sonundan devam et.
        if let size = fileSize() {
            offset = size > Self.backlogBytes ? size - Self.backlogBytes : 0
            fileID = currentFileID()
            readNewData(notify: false, skipFirstPartialLine: offset > 0)
        }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        clients = []
        partialLine = ""
    }

    /// Testler ve zamanlayıcı için: dosyadaki yeni satırları işle.
    public func poll() {
        guard let size = fileSize() else { return }
        let id = currentFileID()
        if id != fileID || size < offset {
            // Günlük döndürüldü ya da yeniden oluşturuldu: baştan oku.
            fileID = id
            offset = 0
            partialLine = ""
        }
        guard size > offset else { return }
        readNewData(notify: true, skipFirstPartialLine: false)
    }

    // MARK: - Ayrıştırma

    /// Bir günlük satırını çözer. Yalnızca uzaktan (`kind=Remote`) istemciler sayılır.
    public static func parse(_ line: String) -> TernLogEvent? {
        if line.contains("daemon started") { return .daemonStarted }
        guard line.contains("kind=Remote") else { return nil }
        let attached = line.contains("daemon client attached")
        let detached = line.contains("daemon client detached")
        guard attached || detached, let id = clientID(in: line) else { return nil }
        return attached ? .attached(id) : .detached(id)
    }

    /// Olayları sırayla uygular; açık bağlantıların kümesini döndürür.
    public static func apply(_ events: [TernLogEvent], to clients: Set<Int>) -> Set<Int> {
        var result = clients
        for event in events {
            switch event {
            case .attached(let id): result.insert(id)
            case .detached(let id): result.remove(id)
            case .daemonStarted: result.removeAll()
            }
        }
        return result
    }

    static func clientID(in line: String) -> Int? {
        guard let range = line.range(of: " id=") else { return nil }
        let digits = line[range.upperBound...].prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        return Int(digits)
    }

    // MARK: - Dosya

    private func readNewData(notify: Bool, skipFirstPartialLine: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            // Bir seferde en fazla 1 MB; kalan bir sonraki turda okunur.
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { return }
            offset += UInt64(data.count)
            var text = partialLine + String(decoding: data, as: UTF8.self)
            if skipFirstPartialLine, let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }
            var lines = text.components(separatedBy: "\n")
            partialLine = lines.removeLast()
            if partialLine.count > 4096 { partialLine = "" }
            let events = lines.compactMap(Self.parse)
            guard !events.isEmpty else { return }
            for event in events {
                let before = clients
                clients = Self.apply([event], to: clients)
                guard notify else { continue }
                switch event {
                case .attached(let id) where !before.contains(id): onClientEvent?(true)
                case .detached(let id) where before.contains(id): onClientEvent?(false)
                case .daemonStarted where !before.isEmpty:
                    // Tern yeniden başladı: önceki bağlantılar kapandı.
                    onClientEvent?(false)
                default: break
                }
            }
        } catch {
            return
        }
    }

    private func fileSize() -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }

    private func currentFileID() -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}
