import Foundation
import PusuCore

func runCommandParserChecks() {
    func parse(_ args: String...) -> PusuCommand? {
        CommandParser.parse(["pusu"] + args)
    }

    expectEqual(parse("on", "90"), .on(minutes: 90), "cli: on 90")
    expectEqual(parse("on", "1h30m"), .on(minutes: 90), "cli: on 1h30m")
    expectEqual(parse("on", "2h"), .on(minutes: 120), "cli: on 2h")
    expectEqual(parse("on", "1s30d"), .on(minutes: 90), "cli: Türkçe kısaltma")
    expectEqual(parse("on"), .on(minutes: nil), "cli: on süresiz/varsayılan")
    expectEqual(parse("off"), .off, "cli: off")
    expectEqual(parse("toggle"), .toggle, "cli: toggle")
    expectEqual(parse("vnc"), .vnc, "cli: vnc")
    expectEqual(parse("settings"), .settings, "cli: settings")
    expectEqual(parse("--on", "45"), .on(minutes: 45), "cli: eski --on 45")
    expectEqual(parse("--on=2h"), .on(minutes: 120), "cli: eski --on=2h")
    expectEqual(parse("--off"), .off, "cli: eski --off")
    expectEqual(parse("lid", "on"), .lid(on: true), "cli: lid on")
    expectEqual(parse("lid", "kapat"), .lid(on: false), "cli: lid kapat")
    expectEqual(parse("lid"), .lid(on: nil), "cli: lid değiştir")
    expectNil(parse("lid", "maybe"), "cli: lid geçersiz argüman")
    expectNil(parse(), "cli: argümansız komut yok")
    expectNil(parse("bogus"), "cli: bilinmeyen komut")

    expectNil(CommandParser.parseDuration("0"), "süre: sıfır")
    expectNil(CommandParser.parseDuration("-5"), "süre: negatif")
    expectNil(CommandParser.parseDuration("abc"), "süre: metin")
    expectNil(CommandParser.parseDuration("90x"), "süre: bilinmeyen birim")
    expectNil(CommandParser.parseDuration("1h30"), "süre: birimsiz kuyruk")
    expectNil(CommandParser.parseDuration("٣٠"), "süre: ASCII olmayan rakam")
    expectNil(CommandParser.parseDuration("999999999999999999999h"), "süre: taşma çökertmez")
    expectNil(CommandParser.parseDuration("9999999h"), "süre: bir yıldan uzun")
    expectEqual(CommandParser.parseDuration(" 30M "), 30, "süre: boşluk ve büyük harf")
    expectEqual(CommandParser.parseDuration("525600"), 525_600, "süre: tam bir yıl")

    func url(_ string: String) -> PusuCommand? {
        URL(string: string).flatMap(CommandParser.parse(url:))
    }
    expectEqual(url("pusu://on?minutes=30"), .on(minutes: 30), "url: on 30")
    expectEqual(url("pusu://on?minutes=1h"), .on(minutes: 60), "url: on 1h")
    expectEqual(url("pusu://on"), .on(minutes: nil), "url: on")
    expectEqual(url("pusu://TOGGLE"), .toggle, "url: büyük harf")
    expectNil(url("pusu://diagnostics"), "url: tanılama web'den tetiklenemez")
    expectNil(url("https://example.com/on"), "url: başka şema")
    expectNil(url("pusu://rm-rf"), "url: bilinmeyen komut")
    expectNil(url("pusu://lid-on"), "url: kapak modu web'den tetiklenemez")

    expectEqual(PusuCommand(wireName: "on", minutes: -5), .on(minutes: nil), "wire: negatif dakika yok sayılır")
    expectNil(PusuCommand(wireName: "nope", minutes: nil), "wire: bilinmeyen")
    for command in [PusuCommand.toggle, .on(minutes: 5), .off, .blackout, .lock, .vnc, .wake, .settings, .diagnostics, .lid(on: true), .lid(on: false), .lid(on: nil)] {
        expectEqual(PusuCommand(wireName: command.wireName, minutes: command.minutes), command, "wire: gidiş-dönüş \(command.wireName)")
    }
}

func runHelperVersionChecks() {
    expect(HelperProtocol.isCurrent(HelperStatus(version: HelperProtocol.version)), "helper: güncel sürüm")
    expect(!HelperProtocol.isCurrent(HelperStatus(version: "1.0")), "helper: eski sürüm")
    expect(!HelperProtocol.isCurrent(nil), "helper: yok")
    expectEqual(HelperProtocol.defaultSocketPath, "/var/run/local.kan.pusu.helper.sock", "helper: sabit soket yolu")

    let cancelled = CommandResult(status: Shell.cancelledStatus, stdout: "", stderr: "")
    expect(cancelled.wasCancelled, "shell: iptal durumu")
    expect(!CommandResult(status: 1, stdout: "", stderr: "").wasCancelled, "shell: normal hata iptal değil")
}

func runLocalizationChecks() {
    Localization.force(.english)
    defer { Localization.force(.turkish) }

    expectEqual(L("Türkçe", "English"), "English", "dil: İngilizce seçili")
    expectEqual(PusuDuration.indefinite.label, "Indefinitely", "en: süresiz")
    expectEqual(PusuDuration.oneHour.label, "1 hour", "en: 1 saat tekil")
    expectEqual(PusuDuration.twoHours.label, "2 hours", "en: 2 saat çoğul")
    expectEqual(PusuDuration(minutes: 90).label, "1 h 30 min", "en: 90 dk")
    expectEqual(PusuDuration(minutes: 1).label, "1 minute", "en: 1 dk tekil")
    expectEqual(PusuDuration(seconds: 45).shortLabel, "45s", "en: kompakt saniye")
    expectEqual(PusuDuration(minutes: 90).shortLabel, "1h 30m", "en: kompakt saat")
    expectEqual(PusuDuration(minutes: 60 * 26).shortLabel, "1d 2h", "en: kompakt gün")
    expectEqual(TimeText.countdown(86_400 + 3_661), "1d 01:01", "en: geri sayım gün")
    expectEqual(Localization.percent(20), "20%", "en: yüzde")
    expectEqual(battery(50).powerLabel, "On battery · 50%", "en: pil etiketi")
    expectEqual(SessionStopReason.timer.label, "Time is up", "en: bitiş sebebi")
    expectEqual(HotKeyPreset.off.title, "Off", "en: kısayol kapalı")

    Localization.force(.turkish)
    expectEqual(Localization.percent(20), "%20", "tr: yüzde")
    expectEqual(battery(50).powerLabel, "Pilde · %50", "tr: pil etiketi")
    expectEqual(SessionStopReason.timer.label, "Süre doldu", "tr: bitiş sebebi")
    expectEqual(AppLanguage.english.title, "English", "dil: seçenek kendi dilinde")
    expectEqual(AppLanguage.turkish.title, "Türkçe", "dil: seçenek kendi dilinde")
}

func runClockFormatChecks() {
    var components = DateComponents()
    components.year = 2026; components.month = 1; components.day = 2
    components.hour = 9; components.minute = 5
    let date = Calendar.current.date(from: components)!
    Localization.force(.turkish)
    expectEqual(TimeText.clock(date), "09:05", "saat: Türkçe 24 saat")
    Localization.force(.english)
    let english = TimeText.clock(date)
    expect(english.hasPrefix("9:05") && english.hasSuffix("AM"), "saat: İngilizce 12 saat (\(english))")
    Localization.force(.turkish)
}

func runShellTimeoutChecks() {
    let slow = Shell.run("/bin/sleep", ["5"], timeout: 0.3)
    expect(slow.timedOut, "shell: zaman aşımı algılanır")
    expect(!slow.failureDescription.isEmpty, "shell: zaman aşımı mesajı boş değil")
    let failing = Shell.run("/usr/bin/false")
    expect(!failing.succeeded && !failing.timedOut, "shell: normal hata")
    expect(failing.failureDescription.contains("1"), "shell: boş çıktıda çıkış kodu")
}
