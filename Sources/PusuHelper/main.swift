import Foundation
import Darwin
import PusuCore

private let helperVersion = HelperProtocol.version
private let arguments = CommandLine.arguments

/// Yardımcıyı kuran uygulamanın yolu (`--app-bundle`). Uygulama kaldırılınca yardımcı da
/// kendini kaldırır; yol yoksa (eski kurulum) bu izleme yapılmaz.
private let appBundlePath: String? = {
    guard let index = arguments.firstIndex(of: "--app-bundle"), arguments.indices.contains(index + 1) else { return nil }
    let path = arguments[index + 1]
    return AppPresenceTracker.isValidBundlePath(path) ? path : nil
}()

/// Uygulamanın varlığı. Yalnızca seri kuyruktan erişilir. Herhangi bir istemci isteği
/// (uygulama 30 sn'de bir yoklar) uygulamanın çalıştığını gösterir ve sayacı sıfırlar.
private var presence = AppPresenceTracker()
/// `launchctl bootout` başarısız olduysa bir sonraki kontrolde yeniden denenir.
private var bootoutPending = false

private func log(_ message: String) {
    let formatter = ISO8601DateFormatter()
    fputs("[\(formatter.string(from: Date()))] \(message)\n", stderr)
}

private func currentSleepDisabled() -> Bool? {
    let result = Shell.run("/usr/bin/pmset", ["-g"])
    guard result.succeeded else { return nil }
    for line in result.stdout.split(separator: "\n") {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if parts.first == "SleepDisabled", parts.count >= 2 {
            return parts[1] == "1"
        }
    }
    return nil
}

private func setSleepDisabled(_ disabled: Bool) -> Bool {
    let result = Shell.run("/usr/bin/pmset", ["-a", "disablesleep", disabled ? "1" : "0"])
    if !result.succeeded {
        log("pmset failed: \(result.combinedOutput)")
    }
    return result.succeeded
}

private func readOriginal() -> Bool? {
    guard let text = try? String(contentsOfFile: HelperProtocol.statePath, encoding: .utf8) else {
        return nil
    }
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if value == "1" { return true }
    if value == "0" { return false }
    return nil
}

private func writeOriginal(_ value: Bool) -> Bool {
    let text = "\(value ? 1 : 0)\n"
    do {
        try text.write(toFile: HelperProtocol.statePath, atomically: true, encoding: .utf8)
        return true
    } catch {
        log("state write failed: \(error.localizedDescription)")
        return false
    }
}

private func removeOriginal() {
    try? FileManager.default.removeItem(atPath: HelperProtocol.statePath)
}

private func status(ok: Bool = true, error: String? = nil) -> HelperStatus {
    HelperStatus(
        ok: ok,
        version: helperVersion,
        sleepDisabled: currentSleepDisabled() ?? false,
        original: readOriginal(),
        error: error,
        appBundle: appBundlePath
    )
}

private func handle(command: String) -> HelperStatus {
    guard let parsed = HelperCommand(rawValue: command) else {
        return status(ok: false, error: "unknown command: \(command.prefix(32))")
    }

    switch parsed {
    case .ping, .status:
        return status()

    case .lidOn:
        if readOriginal() == nil {
            let original = currentSleepDisabled() ?? false
            // Orijinal değer kaydedilemezse ayarı değiştirmeyiz: aksi hâlde geri yükleyecek
            // hiçbir kayıt kalmaz.
            guard writeOriginal(original) else {
                return status(ok: false, error: "state write failed")
            }
        }
        guard setSleepDisabled(true) else {
            return status(ok: false, error: "pmset disablesleep 1 failed")
        }
        return status()

    case .lidOff:
        let original = readOriginal() ?? false
        guard setSleepDisabled(original) else {
            return status(ok: false, error: "pmset disablesleep restore failed")
        }
        removeOriginal()
        return status()
    }
}

private func handleClient(_ client: Int32) {
    // Tek iş parçacıklı sunucu: yavaş ya da sessiz bir istemci diğerlerini kilitlemesin.
    var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSigPipe: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    var uid: uid_t = 0
    var gid: gid_t = 0
    if getpeereid(client, &uid, &gid) != 0 {
        log("getpeereid failed")
        return
    }
    // Yetki sınırı soketin 0660 root:admin izinleridir: yalnızca admin grubu bağlanabilir
    // (ve admin zaten sudo kullanabilir). Konsol kullanıcısı kontrolü hızlı kullanıcı
    // geçişinde meşru sahibi dışarıda bıraktığı için kullanılmaz.

    // Bir istemci bağlandı: uygulama (ya da CLI) çalışıyor demektir.
    _ = presence.observe(appExists: true)

    // Komutlar kısa sabit kelimelerdir; 256 bayttan uzun girdiyi okumayız.
    var buffer = [UInt8](repeating: 0, count: 256)
    let count = buffer.withUnsafeMutableBytes { bytes in
        read(client, bytes.baseAddress, bytes.count)
    }
    guard count > 0 else { return }

    let line = buffer[0..<count].split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: false).first ?? []
    let command = String(decoding: line, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let result = handle(command: command)
    if command == HelperCommand.lidOn.rawValue || command == HelperCommand.lidOff.rawValue {
        log("\(command) by uid=\(uid) gid=\(gid) -> ok=\(result.ok) sleepDisabled=\(result.sleepDisabled)")
        trimLogIfNeeded()
    }

    guard var data = try? JSONEncoder().encode(result) else { return }
    data.append(0x0A)
    data.withUnsafeBytes { bytes in
        _ = write(client, bytes.baseAddress, bytes.count)
    }
}

/// Log dosyası sınırsız büyümesin: 512 KB'ı aşarsa baştan başlat.
private func trimLogIfNeeded() {
    let path = HelperProtocol.logPath
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attributes[.size] as? NSNumber, size.intValue > 512 * 1024
    else { return }
    _ = ftruncate(STDERR_FILENO, 0)
    _ = lseek(STDERR_FILENO, 0, SEEK_SET)
    log("log truncated (was \(size.intValue) bytes)")
}

/// Kalıcı sistem loguna da yaz: yardımcının kendi log dosyası kaldırılırken silinir.
private func systemLog(_ message: String) {
    log(message)
    let logger = Process()
    logger.executableURL = URL(fileURLWithPath: "/usr/bin/logger")
    logger.arguments = ["-t", "pusu-helper", message]
    try? logger.run()
    logger.waitUntilExit()
}

/// `launchctl bootout`'u bekletmeden başlatır; başarısız olursa bir sonraki kontrolde yeniden denenir.
/// (Başarılı olursa launchd bize SIGTERM gönderir ve süreç orada biter.)
private func requestBootout() {
    bootoutPending = true
    let bootout = Process()
    bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    bootout.arguments = ["bootout", "system/\(HelperProtocol.label)"]
    bootout.terminationHandler = { process in
        if process.terminationStatus != 0 {
            log("launchctl bootout failed (\(process.terminationStatus)); will retry")
        }
    }
    do {
        try bootout.run()
    } catch {
        log("launchctl bootout could not start: \(error.localizedDescription)")
    }
}

/// Uygulama kaldırılmış: SleepDisabled'ı geri yükle, dosyaları sil ve launchd'den çık.
/// Geri yükleme başarısız olursa hiçbir şey silinmez; bir sonraki kontrolde yeniden denenir.
/// Bootout başarısız olursa süreç çıkmaz (dosyalar silindiği için KeepAlive onu yeniden
/// başlatamazdı); soket kapalı bekler ve bir sonraki kontrolde yeniden dener.
private func selfUninstall(reason: String) {
    if bootoutPending {
        requestBootout()
        return
    }
    if let original = readOriginal() {
        guard setSleepDisabled(original) else {
            log("self-uninstall postponed: SleepDisabled restore failed")
            return
        }
    }
    removeOriginal()
    systemLog("self-uninstall: \(reason)")
    for path in [HelperProtocol.daemonPlistPath, HelperProtocol.installedBinaryPath, HelperProtocol.logPath] {
        try? FileManager.default.removeItem(atPath: path)
    }
    unlink(HelperProtocol.defaultSocketPath)
    requestBootout()
}

private func serve() -> Never {
    guard geteuid() == 0 else {
        log("must run as root")
        exit(2)
    }

    signal(SIGPIPE, SIG_IGN)
    umask(0o007)
    trimLogIfNeeded()
    // Log yalnızca root tarafından okunabilsin.
    chmod(HelperProtocol.logPath, 0o600)

    // Bağlantılar ve SIGTERM aynı seri kuyrukta işlenir: kapanış, yarım kalmış bir
    // lid-on komutuyla yarışamaz.
    let queue = DispatchQueue(label: "local.kan.pusu.helper")

    // launchd yardımcıyı durdurduğunda (kaldırma, `launchctl bootout`, Homebrew uninstall)
    // kapak modu açık kalmasın: SleepDisabled'ı kaydedilen eski değerine döndür.
    signal(SIGTERM, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
    termination.setEventHandler {
        if let original = readOriginal() {
            if setSleepDisabled(original) {
                removeOriginal()
                log("SIGTERM: SleepDisabled restored to \(original ? 1 : 0)")
            } else {
                // Kaydı koru: kaldırma betikleri ya da bir sonraki başlatma geri yükleyebilsin.
                log("SIGTERM: SleepDisabled restore failed; state kept")
            }
        }
        exit(0)
    }
    termination.resume()

    // Uygulama izleme: dakikada bir; Homebrew güncellemesi gibi kısa boşluklar tolere edilir.
    var presenceTimer: DispatchSourceTimer?
    if let appBundlePath {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler {
            let exists = AppPresenceTracker.bundleExists(atPath: appBundlePath)
            if presence.observe(appExists: exists) {
                selfUninstall(reason: "\(appBundlePath) missing for \(Int(presence.gracePeriod / 60)) minutes")
            }
        }
        timer.resume()
        presenceTimer = timer
    }

    // Root süreçte ortam değişkenleri dikkate alınmaz; yol her zaman sabittir.
    let path = HelperProtocol.defaultSocketPath
    unlink(path)

    let server = socket(AF_UNIX, SOCK_STREAM, 0)
    guard server >= 0 else {
        log("socket() failed: \(String(cString: strerror(errno)))")
        exit(3)
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    _ = path.withCString { source in
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { destination in
                strncpy(destination, source, pathCapacity - 1)
            }
        }
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            bind(server, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindResult == 0 else {
        log("bind failed: \(String(cString: strerror(errno)))")
        close(server)
        exit(4)
    }

    guard listen(server, 16) == 0 else {
        log("listen failed: \(String(cString: strerror(errno)))")
        close(server)
        exit(5)
    }

    if chmod(path, 0o660) != 0 || chown(path, 0, getgrnam("admin")?.pointee.gr_gid ?? 80) != 0 {
        log("socket permissions could not be set: \(String(cString: strerror(errno)))")
        exit(6)
    }

    log("pusu-helper \(helperVersion) listening on \(path)")
    let acceptSource = DispatchSource.makeReadSource(fileDescriptor: server, queue: queue)
    acceptSource.setEventHandler {
        var clientAddress = sockaddr_un()
        var length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let client = withUnsafeMutablePointer(to: &clientAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                accept(server, sockaddrPointer, &length)
            }
        }
        guard client >= 0 else { return }
        handleClient(client)
        close(client)
    }
    acceptSource.resume()
    withExtendedLifetime((termination, acceptSource, presenceTimer)) {
        dispatchMain()
    }
}

if arguments.contains("--version") {
    print(helperVersion)
    exit(0)
}

if arguments.contains("--check") {
    let result = status()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(result) {
        print(String(data: data, encoding: .utf8) ?? "{}")
    }
    exit(0)
}

serve()
