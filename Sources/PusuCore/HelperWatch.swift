import Foundation

/// Yardımcının tek bir kontrolde görünen durumu.
public enum HelperProbe: Equatable {
    case running
    /// launchd kaydı (plist) yerinde ama yardımcı yanıt vermiyor.
    case notResponding
    /// launchd kaydı yok: yardımcı bu Mac'ten kaldırılmış.
    case notInstalled
}

public enum HelperProblem: Equatable {
    case removed
    case notResponding
}

/// Yardımcı bir kez kurulup çalıştıysa ve sonra Pusu'nun dışında kaybolduysa bunu fark eder.
///
/// Örnek: eski bir Homebrew cask'ının kaldırma adımları `brew upgrade` sırasında yardımcıyı sildi;
/// kullanıcı bunu ancak kapak modu parola isteyince anladı. Artık olay günlüğüne kayıt düşülür ve
/// tek bir bildirim gösterilir.
///
/// "Yardımcı beklenir" bilgisi küçük bir işaret dosyasında tutulur: yardımcı çalışırken görülünce
/// ya da Pusu onu kurunca yazılır, Pusu kaldırınca (Ayarlar veya `pusu uninstall-helper`) silinir.
/// Hiç kurmamış biri uyarı görmez. Kısa kesintiler (kurulumda `kickstart -k`, yeniden başlatma)
/// için sorun `confirmDelay` sonra ikinci kez görülmeden bildirilmez.
public final class HelperWatch {
    public static let confirmDelay: TimeInterval = 15
    public static let interval: TimeInterval = 5 * 60

    public static var defaultMarkerURL: URL {
        RuntimePaths.supportDirectory.appendingPathComponent("helper-expected")
    }

    public enum Outcome: Equatable {
        case none
        /// Sorun ilk kez görüldü; `confirmDelay` sonra yeniden kontrol edilmeli.
        case needsConfirmation
        /// Sorun doğrulandı (bir kez bildirilir).
        case missing(HelperProblem)
        /// Bildirilmiş bir sorundan sonra yardımcı yeniden çalışıyor.
        case restored
    }

    private let probe: () -> HelperProbe
    private let markerURL: URL
    private let events: EventRecording?
    private let lock = NSLock()
    private var pending: HelperProblem?
    private var reported: HelperProblem?
    private var changing = false

    public init(
        markerURL: URL = HelperWatch.defaultMarkerURL,
        events: EventRecording?,
        probe: @escaping () -> HelperProbe = HelperWatch.systemProbe
    ) {
        self.markerURL = markerURL
        self.events = events
        self.probe = probe
    }

    /// Ana thread'de çağrılmamalı: yardımcıya soket üzerinden sorar (en çok ~2 sn).
    public static func systemProbe() -> HelperProbe {
        if HelperClient.ping(timeout: 2) != nil { return .running }
        return HelperInstaller.daemonPlistExists ? .notResponding : .notInstalled
    }

    public var expectsHelper: Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
    }

    public static func setExpected(_ expected: Bool, markerURL: URL = HelperWatch.defaultMarkerURL) {
        if expected {
            guard !FileManager.default.fileExists(atPath: markerURL.path) else { return }
            try? FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: markerURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        } else {
            try? FileManager.default.removeItem(at: markerURL)
        }
    }

    public func check() -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        guard !changing else { return .none }

        let state = probe()
        if state == .running {
            if !expectsHelper { Self.setExpected(true, markerURL: markerURL) }
            pending = nil
            guard reported != nil else { return .none }
            reported = nil
            events?.record("Helper is running again")
            return .restored
        }

        guard expectsHelper else {
            pending = nil
            return .none
        }
        guard reported == nil else { return .none }
        let problem: HelperProblem = state == .notInstalled ? .removed : .notResponding
        guard pending != nil else {
            pending = problem
            return .needsConfirmation
        }
        pending = nil
        reported = problem
        switch problem {
        case .removed:
            events?.record("Helper missing: it was removed outside Pusu (lid mode will ask for a password)")
        case .notResponding:
            events?.record("Helper not responding (its launchd job is still installed)")
        }
        return .missing(problem)
    }

    /// Pusu yardımcıyı kurarken ya da kaldırırken kontrolleri durdurur.
    public func beginChange() {
        lock.lock()
        changing = true
        pending = nil
        lock.unlock()
    }

    public func endChange() {
        lock.lock()
        changing = false
        pending = nil
        reported = nil
        lock.unlock()
    }
}
