import Foundation

public struct CommandResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { status == 0 }

    /// Kullanıcı macOS yönetici parolası penceresini iptal etti.
    public var wasCancelled: Bool { status == Shell.cancelledStatus }

    /// Komut süre sınırını aştı ve sonlandırıldı.
    public var timedOut: Bool { status == Shell.timedOutStatus }

    /// Hata mesajı: çıktı boşsa en azından ne olduğunu söyler.
    public var failureDescription: String {
        let output = combinedOutput
        if !output.isEmpty { return output }
        if timedOut { return L("Komut zaman aşımına uğradı.", "The command timed out.") }
        return L("Çıkış kodu \(status).", "Exit code \(status).")
    }

    public var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

public enum Shell {
    /// `runAsAdmin` kullanıcı iptalinde bu durum kodunu döndürür.
    public static let cancelledStatus: Int32 = 128
    /// `run` süre sınırını aşan komutlar için bu durum kodunu döndürür.
    public static let timedOutStatus: Int32 = -2
    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        timeout: TimeInterval = 15
    ) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        var didTimeOut = false
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            didTimeOut = true
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 2)
        }

        let outData = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""

        return CommandResult(
            status: (didTimeOut || process.isRunning) ? timedOutStatus : process.terminationStatus,
            stdout: out.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: err.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Çok satırlı bir kabuk betiğini standart macOS yönetici parolası penceresinden sonra root olarak çalıştırır.
    ///
    /// Betik diske yazılmaz: `osascript`'e argüman olarak verilir ve `do shell script` ile
    /// `/bin/sh -c` üzerinden çalışır. Böylece aynı kullanıcının başka bir süreci, parola
    /// penceresi açıkken root'un çalıştıracağı içeriği değiştiremez.
    @discardableResult
    public static func runAsAdmin(script: String) -> CommandResult {
        let body = "set -eu\n\(script)\n"
        let result = run("/usr/bin/osascript", [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with administrator privileges",
            "-e", "end run",
            body,
        ], timeout: 180)

        if result.timedOut {
            return CommandResult(
                status: timedOutStatus,
                stdout: "",
                stderr: L(
                    "Yönetici parolası penceresi 3 dakika içinde yanıtlanmadı.",
                    "The administrator password prompt wasn't answered within 3 minutes."
                )
            )
        }

        // osascript, kullanıcı iptalinde "User canceled. (-128)" ile çıkar.
        if result.status != 0, result.stderr.contains("(-128)") {
            return CommandResult(
                status: cancelledStatus,
                stdout: result.stdout,
                stderr: L("Yönetici izni verilmedi.", "Administrator permission was not granted.")
            )
        }
        return result
    }

    @discardableResult
    public static func runAsAdmin(command: String) -> CommandResult {
        runAsAdmin(script: command)
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
