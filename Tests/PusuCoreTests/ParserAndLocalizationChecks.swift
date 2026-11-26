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
    expectEqual(parse("update"), .update, "cli: update")
    expectEqual(PusuCommand(wireName: "update", minutes: nil), .update, "bildirim: update")
    expectNil(CommandParser.parse(url: URL(string: "pusu://update")!), "url: update kabul edilmez")
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

    expectNil(PusuCommand(wireName: "on", minutes: -5), "wire: negatif dakika reddedilir")
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

/// Güvenlik denetimi bulgularının regresyon testleri.
func runSecurityPolicyChecks() {
    func url(_ string: String) -> PusuCommand? {
        URL(string: string).flatMap(CommandParser.parse(url:))
    }
    // URL yalnızca zararsız komutlara izin verir
    expectNil(url("pusu://vnc"), "url: vnc kapalı")
    expectNil(url("pusu://lock"), "url: lock kapalı")
    expectNil(url("pusu://blackout"), "url: blackout kapalı")
    expectNil(url("pusu://lid"), "url: lid kapalı")
    expectNil(url("pusu://diagnostics"), "url: diagnostics kapalı")
    expectEqual(url("pusu://wake"), .wake, "url: wake açık")
    expectEqual(url("pusu://settings"), .settings, "url: settings açık")
    // URL süresi 8 saatle sınırlı
    expectEqual(url("pusu://on?minutes=525600"), .on(minutes: CommandParser.maxURLMinutes), "url: uzun süre 8 saate iner")
    expectEqual(url("pusu://on?minutes=90"), .on(minutes: 90), "url: normal süre aynen")

    // Dağıtık bildirim: süre sınırı ve tanılama yasağı
    expectNil(PusuCommand(wireName: "on", minutes: 200_000_000_000_000_000), "wire: devasa dakika reddedilir")
    expectEqual(PusuCommand(wireName: "on", minutes: CommandParser.maxMinutes), .on(minutes: CommandParser.maxMinutes), "wire: üst sınır kabul")
    expect(!CommandParser.isAllowedFromDistributedNotification(.diagnostics), "wire: tanılama reddedilir")
    expect(CommandParser.isAllowedFromDistributedNotification(.lid(on: true)), "wire: lid (yalnız yardımcı varsa) izinli")

    // Görüntüleme kodu aşırı değerlerde çökmez
    expect(!PusuDuration(seconds: 1e300).label.isEmpty, "süre: 1e300 etiketi çökmez")
    expect(!PusuDuration(seconds: 1e300).shortLabel.isEmpty, "süre: 1e300 kısa etiket çökmez")
    expect(!TimeText.countdown(.infinity).isEmpty, "geri sayım: sonsuz çökmez")
    expect(!TimeText.countdown(.nan).isEmpty, "geri sayım: NaN çökmez")

    // Yardımcı özeti
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pusu-sha-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("helper")
    try? Data("pusu".utf8).write(to: file)
    expectEqual(HelperInstaller.sha256(of: file), "d4822ddc3221d33dc53dab8616f2bd4d6039786ce432123a99a7571c50162b6c", "sha: bilinen özet")
    expectNil(HelperInstaller.sha256(of: directory.appendingPathComponent("yok")), "sha: olmayan dosya")
    try? FileManager.default.removeItem(at: directory)
}

/// İsteğe bağlı güncelleme kontrolü: sürüm karşılaştırma, GitHub yanıtı, zamanlama.
func runUpdateCheckerChecks() {
    func v(_ s: String) -> AppVersion? { AppVersion(s) }
    expect(v("1.0.3")! < v("1.0.4")!, "sürüm: yama")
    expect(v("1.0.9")! < v("1.0.10")!, "sürüm: sayısal karşılaştırma")
    expect(v("1.9")! < v("1.10.0")!, "sürüm: farklı uzunluk")
    expect(v("v1.2.0")! == v("1.2")!, "sürüm: v öneki ve sondaki sıfır")
    expect(!(v("2.0.0")! < v("1.9.9")!), "sürüm: büyük sürüm")
    expectNil(v("1.0.4-beta"), "sürüm: ön sürüm eki reddedilir")
    expectNil(v("1..2"), "sürüm: boş bileşen")
    expectNil(v("abc"), "sürüm: metin")
    expectNil(v("1.2.3.4.5"), "sürüm: çok bileşen")

    func release(_ json: String) -> AvailableUpdate? {
        UpdateChecker.parseLatestRelease(Data(json.utf8))
    }
    let ok = release(#"{"tag_name":"v1.0.4","html_url":"https://github.com/bilalkan/pusu/releases/tag/v1.0.4","draft":false,"prerelease":false}"#)
    expectEqual(ok?.version, "1.0.4", "github: sürüm")
    expectEqual(ok?.releaseURL.absoluteString, "https://github.com/bilalkan/pusu/releases/tag/v1.0.4", "github: sürüm sayfası")
    expectNil(release(#"{"tag_name":"v1.0.5","draft":true}"#), "github: taslak yok sayılır")
    expectNil(release(#"{"tag_name":"v1.0.5","prerelease":true}"#), "github: ön sürüm yok sayılır")
    expectNil(release(#"{"tag_name":"latest"}"#), "github: bozuk etiket")
    expectNil(release("not json"), "github: bozuk yanıt")
    let evil = release(#"{"tag_name":"v9.9.9","html_url":"https://evil.example/pusu"}"#)
    expectEqual(evil?.releaseURL, UpdateChecker.releasesPage, "github: yabancı adres yerine sabit sürüm sayfası")
    let sneaky = release(#"{"tag_name":"v9.9.9","html_url":"https://github.com/bilalkan/pusu/releases/../../other/repo"}"#)
    expectEqual(sneaky?.releaseURL, UpdateChecker.releasesPage, "github: '..' ile başka repoya kaçış engellenir")

    expectEqual(UpdateChecker.newer(ok, than: "1.0.3"), ok, "newer: yeni sürüm")
    expectNil(UpdateChecker.newer(ok, than: "1.0.4"), "newer: aynı sürüm")
    expectNil(UpdateChecker.newer(ok, than: "1.1.0"), "newer: daha eski uzak sürüm")
    expectNil(UpdateChecker.newer(ok, than: "dev"), "newer: geliştirme derlemesi")

    let now = Date(timeIntervalSince1970: 1_000_000)
    expect(!UpdateChecker.isDue(enabled: false, lastCheck: nil, now: now), "zaman: kapalıyken asla")
    expect(!UpdateChecker.isDue(enabled: nil, lastCheck: nil, now: now), "zaman: sorulmadıysa asla")
    expect(UpdateChecker.isDue(enabled: true, lastCheck: nil, now: now), "zaman: ilk kez")
    expect(!UpdateChecker.isDue(enabled: true, lastCheck: now.addingTimeInterval(-3600), now: now), "zaman: 1 saat önce denetlendi")
    expect(UpdateChecker.isDue(enabled: true, lastCheck: now.addingTimeInterval(-25 * 3600), now: now), "zaman: 25 saat önce")
    expect(UpdateChecker.isDue(enabled: true, lastCheck: now.addingTimeInterval(3600), now: now), "zaman: saat geri alınmış")

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pusu-cask-\(UUID().uuidString)")
    expect(!UpdateChecker.installedWithHomebrew(caskroomPaths: [dir.path]), "homebrew: yok")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    expect(UpdateChecker.installedWithHomebrew(caskroomPaths: [dir.path]), "homebrew: var")
    try? FileManager.default.removeItem(at: dir)

    let suite = "pusu.tests"
    removeDefaultsSuite(suite)
    let defaults = UserDefaults(suiteName: suite)!
    let store = SettingsStore(defaults: defaults)
    expect(!store.updateCheckEnabled, "ayar: otomatik denetim varsayılan kapalı")
    expect(!store.updateCheckAsked, "ayar: henüz sorulmadı")
    store.updateCheckEnabled = true
    let reloaded = SettingsStore(defaults: defaults)
    expect(reloaded.updateCheckEnabled && reloaded.updateCheckAsked, "ayar: seçim ve sorulma kalıcı")
    removeDefaultsSuite(suite)
}
