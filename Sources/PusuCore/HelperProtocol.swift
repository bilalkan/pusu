import Foundation
import Darwin

public enum HelperCommand: String, Codable {
    case ping
    case status
    case lidOn = "lid-on"
    case lidOff = "lid-off"
    case sleepDisabled = "sleepdisabled"
}

public struct HelperStatus: Codable, Equatable {
    public var ok: Bool
    public var version: String?
    public var sleepDisabled: Bool
    public var original: Bool?
    public var error: String?

    public init(
        ok: Bool = true,
        version: String? = nil,
        sleepDisabled: Bool = false,
        original: Bool? = nil,
        error: String? = nil
    ) {
        self.ok = ok
        self.version = version
        self.sleepDisabled = sleepDisabled
        self.original = original
        self.error = error
    }
}

public enum HelperError: LocalizedError {
    case notRoot
    case installFailed(String)
    case helperUnavailable
    case adminCancelled
    case commandFailed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .notRoot:
            return L("pusu-helper yönetici (root) olarak çalıştırılmalı.", "pusu-helper must run as root.")
        case .installFailed(let detail):
            return L("Yönetici yardımcısı kurulamadı: \(detail)", "Could not install the privileged helper: \(detail)")
        case .helperUnavailable:
            return L("Yönetici yardımcısı çalışmıyor.", "The privileged helper is not running.")
        case .adminCancelled:
            return L("Yönetici izni verilmedi.", "Administrator permission was not granted.")
        case .commandFailed(let detail):
            return L("Komut başarısız: \(detail)", "Command failed: \(detail)")
        case .timedOut:
            return L("Yönetici yardımcısı yanıt vermedi.", "The privileged helper did not respond.")
        }
    }
}

public enum HelperProtocol {
    public static let label = "local.kan.pusu.helper"
    public static let defaultSocketPath = "/var/run/local.kan.pusu.helper.sock"
    public static let statePath = "/var/db/local.kan.pusu.helper.state"
    public static let installedBinaryPath = "/Library/PrivilegedHelperTools/local.kan.pusu.helper"
    public static let daemonPlistPath = "/Library/LaunchDaemons/local.kan.pusu.helper.plist"
    public static let logPath = "/var/log/local.kan.pusu.helper.log"
    /// Uygulamayla birlikte gelen yardımcının protokol sürümü. Yardımcı davranışı
    /// değiştiğinde artırılır; kurulu yardımcı farklıysa arayüz güncelleme önerir.
    public static let version = "1.2"

    /// İstemcinin bağlandığı soket. `PUSU_HELPER_SOCKET` yalnızca root olmayan
    /// süreçlerde (geliştirme/test) dikkate alınır; root yardımcı her zaman sabit yolu kullanır.
    public static var socketPath: String {
        if geteuid() != 0, let override = ProcessInfo.processInfo.environment["PUSU_HELPER_SOCKET"], !override.isEmpty {
            return override
        }
        return defaultSocketPath
    }

    /// Kurulu yardımcı bu uygulama sürümüyle aynı protokolü mü konuşuyor?
    public static func isCurrent(_ status: HelperStatus?) -> Bool {
        guard let status else { return false }
        return status.version == version
    }

    public static func encode(_ command: HelperCommand) -> Data {
        Data((command.rawValue + "\n").utf8)
    }

    public static func decode(_ data: Data) -> HelperStatus? {
        try? JSONDecoder().decode(HelperStatus.self, from: data)
    }
}

public enum HelperClient {
    public static func ping(timeout: TimeInterval = 1.5, socketPath: String? = nil) -> HelperStatus? {
        send(.ping, socketPath: socketPath, timeout: timeout)
    }

    public static func status(timeout: TimeInterval = 1.5, socketPath: String? = nil) -> HelperStatus? {
        send(.status, socketPath: socketPath, timeout: timeout)
    }

    public static func send(
        _ command: HelperCommand,
        socketPath: String? = nil,
        timeout: TimeInterval = 2
    ) -> HelperStatus? {
        let path = socketPath ?? HelperProtocol.socketPath
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { destination in
                    strncpy(destination, source, pathCapacity - 1)
                }
            }
        }
        _ = copied
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return nil }

        let payload = [UInt8](HelperProtocol.encode(command))
        let wrote = payload.withUnsafeBytes { bytes -> Int in
            write(fd, bytes.baseAddress, bytes.count)
        }
        guard wrote == payload.count else { return nil }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count < 16_384 {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(fd, bytes.baseAddress, bytes.count)
            }
            if count <= 0 { break }
            response.append(buffer, count: count)
            if response.contains(0x0A) { break }
        }

        return HelperProtocol.decode(response)
    }
}

public enum LegacyAwakeHelper {
    public static let label = "local.kan.awake.helper"
    public static let socketPath = "/var/run/local.kan.awake.helper.sock"
    public static let statePath = "/var/db/local.kan.awake.helper.state"
    public static let installedBinaryPath = "/Library/PrivilegedHelperTools/local.kan.awake.helper"
    public static let daemonPlistPath = "/Library/LaunchDaemons/local.kan.awake.helper.plist"
    public static let logPath = "/var/log/local.kan.awake.helper.log"
}

public enum HelperInstaller {
    public static var isInstalled: Bool {
        HelperClient.ping() != nil
    }

    public static var daemonPlistExists: Bool {
        FileManager.default.fileExists(atPath: HelperProtocol.daemonPlistPath)
    }

    public static var legacyArtifactsExist: Bool {
        let paths = [
            LegacyAwakeHelper.daemonPlistPath,
            LegacyAwakeHelper.installedBinaryPath,
            LegacyAwakeHelper.socketPath,
            LegacyAwakeHelper.statePath,
        ]
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Eski `local.kan.awake.helper` daemon'ını ve SleepDisabled kalıntısını temizler.
    /// Eski helper çalışıyorsa önce onun üzerinden lid-off gönderilir; erişilemiyorsa
    /// state dosyasındaki orijinal değer yönetici script'i ile geri yüklenir.
    public static func migrateLegacyAwakeHelper() throws {
        guard legacyArtifactsExist else { return }

        if FileManager.default.fileExists(atPath: LegacyAwakeHelper.socketPath) {
            _ = HelperClient.send(.lidOff, socketPath: LegacyAwakeHelper.socketPath, timeout: 2)
        }

        let script = """
        /bin/launchctl bootout system/\(LegacyAwakeHelper.label) >/dev/null 2>&1 || true
        if [ -f \(LegacyAwakeHelper.statePath) ]; then
            ORIGINAL=$(/bin/cat \(LegacyAwakeHelper.statePath))
            case "$ORIGINAL" in 0|1) /usr/bin/pmset -a disablesleep "$ORIGINAL" || true ;; esac
        fi
        /bin/rm -f \(LegacyAwakeHelper.statePath)
        /bin/rm -f \(LegacyAwakeHelper.daemonPlistPath)
        /bin/rm -f \(LegacyAwakeHelper.installedBinaryPath)
        /bin/rm -f \(LegacyAwakeHelper.socketPath)
        """

        let result = Shell.runAsAdmin(script: script)
        guard result.succeeded else {
            if result.wasCancelled { throw HelperError.adminCancelled }
            throw HelperError.installFailed(result.failureDescription)
        }
    }

    public static func install(helperBinary: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: helperBinary.path) else {
            throw HelperError.installFailed(L("pusu-helper çalıştırılabilir dosyası bulunamadı.", "The pusu-helper executable was not found."))
        }

        let plist: [String: Any] = [
            "Label": HelperProtocol.label,
            "ProgramArguments": [HelperProtocol.installedBinaryPath],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "ThrottleInterval": 5,
            "StandardOutPath": HelperProtocol.logPath,
            "StandardErrorPath": HelperProtocol.logPath,
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pusu-helper-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let plistURL = tempDirectory.appendingPathComponent("local.kan.pusu.helper.plist")
        try plistData.write(to: plistURL)

        let script = """
        /usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
        /usr/bin/install -o root -g wheel -m 755 \(Shell.shellQuote(helperBinary.path)) \(HelperProtocol.installedBinaryPath)
        /usr/bin/install -o root -g wheel -m 644 \(Shell.shellQuote(plistURL.path)) \(HelperProtocol.daemonPlistPath)
        /bin/launchctl bootout system/\(HelperProtocol.label) >/dev/null 2>&1 || true
        /bin/launchctl bootstrap system \(HelperProtocol.daemonPlistPath)
        /bin/launchctl kickstart -k system/\(HelperProtocol.label)
        """

        let result = Shell.runAsAdmin(script: script)
        guard result.succeeded else {
            if result.wasCancelled { throw HelperError.adminCancelled }
            throw HelperError.installFailed(result.failureDescription)
        }

        for _ in 0..<30 {
            if HelperProtocol.isCurrent(HelperClient.ping()) { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw HelperError.timedOut
    }

    public static func uninstall() throws {
        let script = """
        /bin/launchctl bootout system/\(HelperProtocol.label) >/dev/null 2>&1 || true
        if [ -f \(HelperProtocol.statePath) ]; then
            ORIGINAL=$(/bin/cat \(HelperProtocol.statePath))
            case "$ORIGINAL" in 0|1) /usr/bin/pmset -a disablesleep "$ORIGINAL" || true ;; esac
        fi
        /bin/rm -f \(HelperProtocol.statePath)
        /bin/rm -f \(HelperProtocol.daemonPlistPath)
        /bin/rm -f \(HelperProtocol.installedBinaryPath)
        /bin/rm -f \(HelperProtocol.defaultSocketPath)
        /bin/rm -f \(HelperProtocol.logPath)
        """
        let result = Shell.runAsAdmin(script: script)
        guard result.succeeded else {
            if result.wasCancelled { throw HelperError.adminCancelled }
            throw HelperError.installFailed(result.failureDescription)
        }
    }
}

public final class LidController: LidControlling {
    private let settings: SettingsStore

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    public var helperAvailable: Bool {
        HelperClient.ping() != nil
    }

    public var usesFallback: Bool {
        settings.fallbackSleepDisabledActive
    }

    public func helperStatus() -> HelperStatus? {
        HelperClient.status()
    }

    /// Reads the global `SleepDisabled` flag. Returns nil if pmset output could not be parsed.
    public func sleepDisabled(timeout: TimeInterval) -> Bool? {
        let result = Shell.run("/usr/bin/pmset", ["-g"], timeout: timeout)
        guard result.succeeded else { return nil }
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.first == "SleepDisabled", parts.count >= 2 {
                return parts[1] == "1"
            }
        }
        return nil
    }

    public var isEnabled: Bool {
        sleepDisabled() == true
    }

    public func setEnabled(_ enabled: Bool, allowPrompt: Bool) throws {
        if enabled {
            if helperAvailable {
                guard let status = HelperClient.send(.lidOn), status.sleepDisabled else {
                    throw HelperError.commandFailed(L("Kapak modu açılamadı.", "Could not turn on lid mode."))
                }
                return
            }

            if sleepDisabled() == true { return }
            guard allowPrompt else { throw HelperError.adminCancelled }
            if !settings.fallbackSleepDisabledActive {
                settings.fallbackSleepDisabledOriginal = sleepDisabled() ?? false
                settings.fallbackSleepDisabledActive = true
            }
            let result = Shell.runAsAdmin(command: "/usr/bin/pmset -a disablesleep 1")
            guard result.succeeded else {
                settings.fallbackSleepDisabledActive = false
                settings.fallbackSleepDisabledOriginal = nil
                if result.wasCancelled { throw HelperError.adminCancelled }
                throw HelperError.commandFailed(result.failureDescription)
            }
            guard sleepDisabled() == true else {
                throw HelperError.commandFailed(L("pmset SleepDisabled ayarlanamadı.", "pmset could not set SleepDisabled."))
            }
        } else {
            if helperAvailable {
                guard let status = HelperClient.send(.lidOff), status.ok else {
                    throw HelperError.commandFailed(L("Kapak modu kapatılamadı.", "Could not turn off lid mode."))
                }
                return
            }

            guard settings.fallbackSleepDisabledActive else { return }
            guard allowPrompt else { throw HelperError.adminCancelled }
            let original = settings.fallbackSleepDisabledOriginal ?? false
            let result = Shell.runAsAdmin(command: "/usr/bin/pmset -a disablesleep \(original ? 1 : 0)")
            guard result.succeeded else {
                if result.wasCancelled { throw HelperError.adminCancelled }
                throw HelperError.commandFailed(result.failureDescription)
            }
            settings.fallbackSleepDisabledActive = false
            settings.fallbackSleepDisabledOriginal = nil
        }
    }
}
