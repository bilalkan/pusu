import Foundation
import Darwin
import PusuCore

private let helperVersion = HelperProtocol.version
private let arguments = CommandLine.arguments

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
        error: error
    )
}

private func handle(command: String) -> HelperStatus {
    guard let parsed = HelperCommand(rawValue: command) else {
        return status(ok: false, error: "unknown command: \(command.prefix(32))")
    }

    switch parsed {
    case .ping, .status, .sleepDisabled:
        return status()

    case .lidOn:
        if readOriginal() == nil {
            let original = currentSleepDisabled() ?? false
            _ = writeOriginal(original)
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
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
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
    // The socket is mode 0660 root:admin. Filesystem permissions are the
    // authorization boundary; keep the peer identity in the log for auditing.
    log("peer uid=\(uid) gid=\(gid)")

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

    guard var data = try? JSONEncoder().encode(result) else { return }
    data.append(0x0A)
    data.withUnsafeBytes { bytes in
        _ = write(client, bytes.baseAddress, bytes.count)
    }
}

private func serve() -> Never {
    guard geteuid() == 0 else {
        log("must run as root")
        exit(2)
    }

    signal(SIGPIPE, SIG_IGN)
    umask(0o007)

    // launchd yardımcıyı durdurduğunda (kaldırma, `launchctl bootout`, Homebrew uninstall)
    // kapak modu açık kalmasın: SleepDisabled'ı kaydedilen eski değerine döndür.
    signal(SIGTERM, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    termination.setEventHandler {
        if let original = readOriginal() {
            _ = setSleepDisabled(original)
            removeOriginal()
            log("SIGTERM: SleepDisabled restored to \(original ? 1 : 0)")
        }
        exit(0)
    }
    termination.resume()

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

    chmod(path, 0o660)
    let adminGID = getgrnam("admin")?.pointee.gr_gid ?? 80
    chown(path, 0, adminGID)

    guard listen(server, 16) == 0 else {
        log("listen failed: \(String(cString: strerror(errno)))")
        close(server)
        exit(5)
    }

    log("pusu-helper \(helperVersion) listening on \(path)")
    while true {
        var clientAddress = sockaddr_un()
        var length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let client = withUnsafeMutablePointer(to: &clientAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                accept(server, sockaddrPointer, &length)
            }
        }
        if client < 0 { continue }
        handleClient(client)
        close(client)
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
