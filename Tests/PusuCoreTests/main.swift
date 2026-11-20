import Foundation
import PusuCore

var failures: [String] = []
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    checks += 1
    if !condition() {
        failures.append("satır \(line): \(message)")
    }
}

func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String, line: UInt = #line) {
    checks += 1
    if lhs != rhs {
        failures.append("satır \(line): \(message) (beklenen: \(rhs), gelen: \(lhs))")
    }
}

func expectNil<T>(_ value: T?, _ message: String, line: UInt = #line) {
    checks += 1
    if value != nil {
        failures.append("satır \(line): \(message) (değer: \(String(describing: value)))")
    }
}

func runChecks(_ name: String, _ body: () -> Void) {
    body()
}

/// Testler makinenin dilinden bağımsız olsun: varsayılan Türkçe, İngilizce bölümleri ayrıca sabitler.
Localization.force(.turkish)

// MARK: - Duration

runChecks("Duration") {
    expectEqual(PusuDuration.indefinite.label, "Süresiz", "süresiz etiketi")
    expectEqual(PusuDuration.oneHour.label, "1 saat", "1 saat etiketi")
    expectEqual(PusuDuration(minutes: 90).label, "1 sa 30 dk", "90 dakika etiketi")
    expectEqual(PusuDuration(minutes: 30).label, "30 dakika", "30 dakika etiketi")
    expectEqual(PusuDuration(seconds: 45).shortLabel, "45sn", "kısa etiket")

    let now = Date(timeIntervalSince1970: 1_000)
    let duration = PusuDuration(minutes: 30)
    let end = duration.endDate(from: now)
    expectEqual(end?.timeIntervalSince1970, 2_800, "bitiş tarihi")
    expectEqual(duration.remaining(until: end, now: now), 1_800, "kalan süre")
    expectEqual(duration.remaining(until: end, now: now.addingTimeInterval(2_000)), 0, "negatif kalan sıfırlanır")

    expectEqual(TimeText.countdown(59), "0:59", "geri sayım 59")
    expectEqual(TimeText.countdown(60), "1:00", "geri sayım 60")
    expectEqual(TimeText.countdown(3_661), "1:01:01", "geri sayım saat")
    expectEqual(TimeText.countdown(86_400 + 3_661), "1g 01:01", "geri sayım gün")
    expectEqual(TimeText.countdown(90_000), "1g 01:00", "geri sayım gün/saat")
    expectEqual(PusuDuration(minutes: 90).shortLabel, "1s 30d", "kompakt saat")
    expectEqual(PusuDuration(minutes: 60 * 26).shortLabel, "1g 2s", "kompakt gün")
}

// MARK: - Battery

runChecks("Battery") {
    func battery(_ percent: Int, onBattery: Bool = true, charging: Bool = false) -> BatteryStatus {
        BatteryStatus(percent: percent, isOnBattery: onBattery, isCharging: charging, isPresent: true)
    }

    expect(BatteryPolicy.shouldStop(battery: battery(9), cutoffEnabled: true, cutoffPercent: 10), "pil eşiği altı")
    expect(BatteryPolicy.shouldStop(battery: battery(10), cutoffEnabled: true, cutoffPercent: 10), "pil eşiği tam sınır")
    expect(!BatteryPolicy.shouldStop(battery: battery(11), cutoffEnabled: true, cutoffPercent: 10), "pil eşiği üstü")
    expect(!BatteryPolicy.shouldStop(battery: battery(5), cutoffEnabled: false, cutoffPercent: 10), "eşik kapalı")
    expect(!BatteryPolicy.shouldStop(battery: battery(5, onBattery: false), cutoffEnabled: true, cutoffPercent: 10), "şarjda")
    expect(!BatteryPolicy.shouldStop(battery: battery(5, charging: true), cutoffEnabled: true, cutoffPercent: 10), "şarj oluyor")

    expect(BatteryPolicy.shouldDisableLid(battery: battery(19), floorEnabled: true, floorPercent: 20), "kapak pil koruması")
    expect(!BatteryPolicy.shouldDisableLid(battery: battery(21), floorEnabled: true, floorPercent: 20), "kapak pil koruması üstü")
    expect(!BatteryPolicy.shouldDisableLid(battery: battery(19), floorEnabled: false, floorPercent: 20), "kapak pil koruması kapalı")

    let desktop = BatteryStatus(percent: 0, isOnBattery: false, isCharging: false, isPresent: false)
    expectEqual(desktop.powerLabel, "Masaüstü", "masaüstü etiketi")
    expectNil(desktop.remainingLabel, "masaüstü kalan süre")
}

// MARK: - Settings

runChecks("Settings") {
    let suite = "pusu.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = SettingsStore(defaults: defaults)
    expect(store.keepDisplayAwake, "varsayılan ekran açık")
    expect(!store.keepSessionUnlocked, "varsayılan oturum kilidi")
    expect(store.batteryCutoffEnabled, "varsayılan pil eşiği açık")
    expectEqual(store.batteryCutoffPercent, 10, "varsayılan pil yüzdesi")
    expectEqual(store.defaultDuration, .indefinite, "varsayılan süre")
    expectEqual(store.hotkeyPreset, .ctrlOptCmdA, "varsayılan kısayol")

    store.keepDisplayAwake = false
    store.keepSessionUnlocked = true
    store.batteryCutoffPercent = 15
    store.defaultDuration = PusuDuration(minutes: 45)
    store.hotkeyPreset = .ctrlOptCmdK
    store.launchAtLogin = true

    let reloaded = SettingsStore(defaults: defaults)
    expect(!reloaded.keepDisplayAwake, "ekran ayarı kalıcı")
    expect(reloaded.keepSessionUnlocked, "oturum ayarı kalıcı")
    expectEqual(reloaded.batteryCutoffPercent, 15, "pil yüzdesi kalıcı")
    expectEqual(reloaded.defaultDuration, PusuDuration(minutes: 45), "süre kalıcı")
    expectEqual(reloaded.hotkeyPreset, .ctrlOptCmdK, "kısayol kalıcı")
    expect(reloaded.launchAtLogin, "giriş öğesi kalıcı")

    expectNil(reloaded.fallbackSleepDisabledOriginal, "fallback başlangıç değeri")
    expect(!reloaded.fallbackSleepDisabledActive, "fallback aktif değil")
    reloaded.fallbackSleepDisabledOriginal = true
    reloaded.fallbackSleepDisabledActive = true
    let again = SettingsStore(defaults: defaults)
    expectEqual(again.fallbackSleepDisabledOriginal, true, "fallback orijinal kalıcı")
    expect(again.fallbackSleepDisabledActive, "fallback aktif kalıcı")
}

// MARK: - Helper protocol

runChecks("Helper protocol") {
    expectEqual(String(data: HelperProtocol.encode(.lidOn), encoding: .utf8), "lid-on\n", "lid-on komutu")
    expectEqual(String(data: HelperProtocol.encode(.ping), encoding: .utf8), "ping\n", "ping komutu")

    let status = HelperStatus(ok: true, version: "1.0", sleepDisabled: true, original: false)
    if let data = try? JSONEncoder().encode(status) {
        expectEqual(HelperProtocol.decode(data), status, "helper status çözümleme")
    } else {
        expect(false, "helper status kodlama")
    }
    expectNil(HelperProtocol.decode(Data("not json".utf8)), "bozuk helper yanıtı")
}

// MARK: - Runtime state

runChecks("Runtime state") {
    let state = RuntimeState(
        pid: 42,
        isOn: true,
        endDate: Date(timeIntervalSince1970: 2_000),
        remaining: 120,
        lidMode: true,
        remoteBlankActive: false,
        remoteLocked: false,
        keepDisplayAwake: true,
        keepSessionUnlocked: true,
        batteryPercent: 77,
        onBattery: true,
        systemAssertion: true,
        displayAssertion: false,
        updatedAt: Date(timeIntervalSince1970: 1_000)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let data = try? encoder.encode(state), let decoded = try? decoder.decode(RuntimeState.self, from: data) {
        expectEqual(decoded.pid, 42, "runtime pid")
        expect(decoded.isOn, "runtime açık")
        expectEqual(decoded.remaining, 120, "runtime kalan")
        expect(decoded.lidMode, "runtime kapak")
        expectEqual(decoded.batteryPercent, 77, "runtime pil")
        expect(decoded.systemAssertion, "runtime assertion")
    } else {
        expect(false, "runtime codable")
    }
}

// MARK: - Shell

runChecks("Shell") {
    expectEqual(Shell.shellQuote("/Applications/Pusu.app"), "'/Applications/Pusu.app'", "shell quote")
    expectEqual(Shell.shellQuote("a b'c"), "'a b'\\''c'", "shell quote tek tırnak")
    let result = Shell.run("/bin/echo", ["hello"])
    expect(result.succeeded, "echo başarılı")
    expectEqual(result.stdout, "hello", "echo çıktısı")
}

// MARK: - Session history

runChecks("Session history") {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pusu-history-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("history.json")
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let battery = BatteryStatus(percent: 77, isOnBattery: true, isCharging: false, isPresent: true)

    let activeURL = directory.appendingPathComponent("active-session.json")
    let store = SessionHistoryStore(historyURL: url, activeURL: activeURL, maxRecords: 2)
    let active = store.begin(duration: .oneHour, at: start)
    expectEqual(active.startedAt, start, "history başlangıç")
    expect(store.active != nil, "history aktif kayıt")
    expect(store.records.isEmpty, "history başlangıçta boş")

    store.end(
        reason: .timer,
        battery: battery,
        at: start.addingTimeInterval(3_600)
    )
    expectNil(store.active, "history bitince aktif temizlenir")
    expectEqual(store.records.count, 1, "history biten kayıt")
    expectEqual(store.records[0].duration, 3_600, "history süre")
    expectEqual(store.records[0].endReason, .timer, "history bitiş sebebi")

    let reloaded = SessionHistoryStore(historyURL: url, activeURL: activeURL, maxRecords: 2)
    expectEqual(reloaded.records.count, 1, "history dosyadan yükleme")
    expectEqual(reloaded.records[0].batteryPercentAtEnd, 77, "history pil")

    for offset in [1, 2] {
        let sessionStart = start.addingTimeInterval(Double(offset) * 10_000)
        reloaded.begin(duration: .fifteenMinutes, at: sessionStart)
        reloaded.markLidUsed(at: sessionStart)
        reloaded.markRemoteUsed(at: sessionStart)
        reloaded.end(
            reason: .user,
            battery: battery,
            at: sessionStart.addingTimeInterval(60)
        )
    }
    expectEqual(reloaded.records.count, 2, "history kayıt sınırı")
    expect(reloaded.records[0].usedLid, "history kapak modu")
    expect(reloaded.records[0].usedRemote, "history VNC modu")

    reloaded.begin(
        duration: .indefinite,
        at: start.addingTimeInterval(30_000)
    )
    let recovered = SessionHistoryStore(historyURL: url, activeURL: activeURL, maxRecords: 3)
    expectEqual(recovered.records.first?.endReason, .interrupted, "history kesinti kurtarma")
    expect(recovered.records.first?.endIsEstimated == true, "history tahmini bitiş")

    recovered.clear()
    expect(recovered.records.isEmpty, "history temizleme")

    let tolerantJSON = """
    {
      "schemaVersion": 1,
      "records": [
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "startedAt": "2026-01-01T10:00:00Z",
          "endedAt": "2026-01-01T10:05:00Z",
          "endReason": "futureReason",
          "usedLid": false,
          "usedRemote": false
        },
        {
          "id": "bozuk"
        }
      ]
    }
    """
    try? tolerantJSON.data(using: .utf8)?.write(to: url)
    let tolerant = SessionHistoryStore(historyURL: url, activeURL: activeURL, maxRecords: 10)
    expectEqual(tolerant.records.count, 1, "history toleranslı kayıt")
    expectEqual(tolerant.records.first?.endReason, .error, "history bilinmeyen bitiş sebebi")

    let duplicateID = "00000000-0000-0000-0000-000000000002"
    let duplicateHistory = """
    {"schemaVersion":1,"records":[{"id":"\(duplicateID)","startedAt":"2026-01-02T10:00:00Z","endedAt":"2026-01-02T10:05:00Z","endReason":"user","usedLid":false,"usedRemote":false}]}
    """
    let duplicateActive = """
    {"id":"\(duplicateID)","startedAt":"2026-01-02T10:00:00Z","lastSeenAt":"2026-01-02T10:05:00Z","requestedDuration":null,"usedLid":false,"usedRemote":false}
    """
    try? duplicateHistory.data(using: .utf8)?.write(to: url)
    try? duplicateActive.data(using: .utf8)?.write(to: activeURL)
    let duplicate = SessionHistoryStore(historyURL: url, activeURL: activeURL, maxRecords: 10)
    expectEqual(duplicate.records.count, 1, "history yinelenen kurtarma")
    expectNil(duplicate.active, "history yinelenen aktif temizlenir")
    expect(!FileManager.default.fileExists(atPath: activeURL.path), "history yinelenen dosya silinir")

    try? FileManager.default.removeItem(at: directory)
}

// MARK: - Komutlar, yardımcı sürümü, dil

runChecks("Command parser") { runCommandParserChecks() }
runChecks("Helper version") { runHelperVersionChecks() }
runChecks("Localization") { runLocalizationChecks() }
runChecks("Clock format") { runClockFormatChecks() }
runChecks("Shell timeout") { runShellTimeoutChecks() }
runChecks("Security policy") { runSecurityPolicyChecks() }

// MARK: - SessionController

runChecks("SessionController") { runSessionControllerChecks() }
runChecks("External commands") { runExternalCommandChecks() }
runChecks("URL strictness") { runURLStrictnessChecks() }

// MARK: - Summary

if failures.isEmpty {
    print("PASS: \(checks) kontrol")
    exit(0)
} else {
    print("FAIL: \(failures.count)/\(checks) kontrol başarısız")
    for failure in failures {
        print("  - \(failure)")
    }
    exit(1)
}
