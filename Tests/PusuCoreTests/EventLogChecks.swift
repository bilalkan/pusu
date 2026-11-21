import Foundation
import PusuCore

func runEventLogChecks() {
    // Satır biçimi ve tarih geri okuma
    do {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let line = EventLog.line(for: "Session on: 1h", at: date)
        expect(line.hasSuffix("  Session on: 1h"), "events: mesaj satır sonunda")
        expectEqual(EventLog.date(ofLine: line), date, "events: tarih geri okunur")
        expectNil(EventLog.date(ofLine: "bozuk satır"), "events: bozuk satırın tarihi yok")
    }

    // Satır sonu ve kontrol karakterleri sahte satır ekleyemez; uzunluk sınırlı
    do {
        let line = EventLog.line(for: "a\n2026-01-01 00:00:00 +0000  fake\r\u{7}", at: Date())
        expect(!line.contains("\n") && !line.contains("\r") && !line.contains("\u{7}"), "events: kontrol karakterleri atılır")
        let long = EventLog.line(for: String(repeating: "x", count: 1_000), at: Date())
        expect(long.count < 400, "events: uzun mesaj kısaltılır")
    }

    // Budama: 3 günden eski ve bozuk satırlar atılır, en fazla maxEntries kalır
    do {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = EventLog.line(for: "eski", at: now.addingTimeInterval(-EventLog.maxAge - 60))
        let fresh = EventLog.line(for: "yeni", at: now.addingTimeInterval(-60))
        let kept = EventLog.retained([old, "bozuk", fresh], now: now)
        expectEqual(kept, [fresh], "events: eski ve bozuk satır atılır")

        let many = (0..<(EventLog.maxEntries + 25)).map {
            EventLog.line(for: "e\($0)", at: now.addingTimeInterval(TimeInterval(-$0)))
        }
        let trimmed = EventLog.retained(many, now: now)
        expectEqual(trimmed.count, EventLog.maxEntries, "events: en fazla maxEntries satır")
        expectEqual(trimmed.last, many.last, "events: en yeni satırlar korunur")
    }

    // Dosyaya yazma, okuma, budama, temizleme ve izinler
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pusu-events-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("events.log")
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let log = EventLog(url: url, now: { clock })
        log.record("bir")
        log.record("iki\nüç")
        expectEqual(log.lines().count, 2, "events: iki satır yazıldı")
        expect(log.tail(1).first?.hasSuffix("iki üç") == true, "events: son satır, satır sonu boşluğa döner")
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? nil
        expectEqual(permissions, 0o600, "events: dosya yalnızca kullanıcıya açık")

        clock = clock.addingTimeInterval(EventLog.maxAge + 1)
        log.record("üç gün sonra")
        log.prune()
        expectEqual(log.lines().count, 1, "events: eski satırlar budandı")
        expect(log.lines().first?.hasSuffix("üç gün sonra") == true, "events: yeni satır kaldı")

        log.clear()
        expect(log.lines().isEmpty, "events: temizlendi")
        try? FileManager.default.removeItem(at: directory)
    }

    // Sembolik bağ izlenmez; önceden gevşek izinli dosya 0600'e çekilir
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pusu-events-link-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("baska-dosya.txt")
        FileManager.default.createFile(atPath: target.path, contents: Data("dokunma\n".utf8))
        let link = directory.appendingPathComponent("events.log")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        EventLog(url: link).record("saldırı")
        expectEqual(try? String(contentsOf: target, encoding: .utf8), "dokunma\n", "events: sembolik bağın hedefine yazılmadı")

        let loose = directory.appendingPathComponent("loose.log")
        FileManager.default.createFile(atPath: loose.path, contents: nil, attributes: [.posixPermissions: 0o644])
        EventLog(url: loose).record("bir")
        let permissions = (try? FileManager.default.attributesOfItem(atPath: loose.path)[.posixPermissions] as? Int) ?? nil
        expectEqual(permissions, 0o600, "events: gevşek izin 0600'e çekildi")
        try? FileManager.default.removeItem(at: directory)
    }

    // SessionController olayları günlüğe düşer
    do {
        let h = SessionHarness(battery: battery(80))
        let c = h.controller!
        c.start(.oneHour)
        c.start(.indefinite)
        c.enterRemoteMode(lock: true)
        c.exitRemoteMode()
        c.enterRemoteMode(lock: false)
        c.stop()
        let messages = h.eventLog.messages
        expectEqual(messages.first, "Session on: 1h", "events: oturum açıldı")
        expect(messages.contains("Duration changed: indefinite"), "events: süre değişti")
        expect(messages.contains("Remote access mode on (lock requested: yes, locked: yes)"), "events: uzak erişim açıldı (kilitli)")
        expect(messages.contains("Remote access mode on (lock requested: no, locked: no)"), "events: uzak erişim açıldı (kilitsiz)")
        expectEqual(messages.filter { $0 == "Remote access mode off (display wake: ok)" }.count, 2, "events: çıkış ve stop uyandırmayı yazar")
        expectEqual(messages.last, "Session off (reason: user)", "events: oturum kapandı")
        h.tearDown()
    }

    // Süre etiketi
    expectEqual(SessionController.logLabel(.indefinite), "indefinite", "events: süresiz etiketi")
    expectEqual(SessionController.logLabel(PusuDuration(seconds: 45)), "45s", "events: saniye etiketi")
    expectEqual(SessionController.logLabel(PusuDuration(minutes: 90)), "1h 30m", "events: saat+dakika etiketi")
    expectEqual(SessionController.logLabel(PusuDuration(minutes: 15)), "15m", "events: dakika etiketi")
}

func runCommandDeliveryChecks() {
    let id = UUID().uuidString
    expect(CommandDelivery.isValidID(id), "ack: UUID geçerli")
    expect(!CommandDelivery.isValidID("../../etc/passwd"), "ack: yol karakterleri geçersiz")
    expect(!CommandDelivery.isValidID("abc"), "ack: kısa kimlik geçersiz")
    expect(!CommandDelivery.isValidID(String(repeating: "a", count: 65)), "ack: uzun kimlik geçersiz")

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pusu-ack-\(UUID().uuidString)")
    CommandDelivery.writeAck(id, to: url)
    expectEqual(CommandDelivery.readAck(from: url), id, "ack: yazılan okunur")
    CommandDelivery.writeAck("x\ny", to: url)
    expectEqual(CommandDelivery.readAck(from: url), id, "ack: geçersiz kimlik yazılmaz")
    try? FileManager.default.removeItem(at: url)
}
