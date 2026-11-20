import Foundation
import PusuCore

/// SessionController durum makinesinin uçtan uca kontrolleri (sahte donanımla).
func runSessionControllerChecks() {
    // Başlat / durdur
    do {
        let h = SessionHarness(battery: battery(80))
        let c = h.controller!
        expect(!c.isOn, "session: başlangıçta kapalı")

        c.start(.oneHour)
        expect(c.isOn, "session: başlatınca açık")
        expect(h.assertions.isSystemHeld, "session: sistem assertion alındı")
        expect(h.assertions.isDisplayHeld, "session: varsayılan ekran assertion")
        expect(h.history.active != nil, "session: aktif geçmiş kaydı")
        expectEqual(h.history.active?.requestedDuration, 3_600, "session: istenen süre")
        expect(c.remaining != nil, "session: kalan süre var")
        expect(h.lastRuntime?.isOn == true, "session: runtime açık yazıldı")

        let activeID = h.history.active?.id
        c.start(.twoHours)
        expectEqual(h.history.active?.id, activeID, "session: açıkken yeniden başlatma yeni kayıt açmaz")
        expectEqual(h.history.active?.requestedDuration, 7_200, "session: süre güncellendi")
        expectEqual(c.duration, .twoHours, "session: yeni süre")

        c.stop(reason: .user)
        expect(!c.isOn, "session: durdurunca kapalı")
        expect(!h.assertions.isSystemHeld, "session: assertion bırakıldı")
        expectNil(c.remaining, "session: kalan süre temizlendi")
        expectNil(h.history.active, "session: aktif kayıt kapandı")
        expectEqual(h.history.records.count, 1, "session: bir geçmiş kaydı")
        expectEqual(h.history.records.first?.endReason, .user, "session: bitiş sebebi kullanıcı")
        expect(h.lastRuntime?.isOn == false, "session: runtime kapalı yazıldı")

        c.stop(reason: .user)
        expectEqual(h.history.records.count, 1, "session: kapalıyken stop kayıt eklemez")
        h.tearDown()
    }

    // Ekran assertion ayarı ve oturum açık kalsın
    do {
        let h = SessionHarness(battery: battery(80)) { settings in
            settings.keepDisplayAwake = false
        }
        let c = h.controller!
        c.start(.indefinite)
        expect(h.assertions.isSystemHeld, "session: sistem assertion")
        expect(!h.assertions.isDisplayHeld, "session: ekran assertion kapalı")

        h.settings.keepDisplayAwake = true
        expect(h.assertions.isDisplayHeld, "session: ayar değişince ekran assertion alındı")

        h.settings.keepSessionUnlocked = true
        expect(h.assertions.isUserActivityHeld, "session: kullanıcı etkinliği bildirildi")
        h.settings.keepSessionUnlocked = false
        expect(!h.assertions.isUserActivityHeld, "session: kullanıcı etkinliği bırakıldı")
        h.tearDown()
    }

    // Süre dolunca planlanan bitiş saati kaydedilir
    do {
        let h = SessionHarness(battery: battery(80))
        let c = h.controller!
        c.start(PusuDuration(minutes: 1))
        let end = c.endDate!
        c.processTick(now: end.addingTimeInterval(-10))
        expect(c.isOn, "timer: süre dolmadan açık")
        expectEqual(c.remaining, 10, "timer: kalan 10 sn")

        c.processTick(now: end.addingTimeInterval(300))
        expect(!c.isOn, "timer: süre dolunca kapandı")
        expectEqual(h.history.records.first?.endReason, .timer, "timer: bitiş sebebi")
        expectEqual(h.history.records.first?.endedAt, end, "timer: uyanma anı değil planlanan bitiş")
        expectEqual(h.stopReasons, [.timer], "timer: stopped olayı")
        h.tearDown()
    }

    // Uzatma
    do {
        let h = SessionHarness(battery: battery(80))
        let c = h.controller!
        c.start(.thirtyMinutes)
        let end = c.endDate!
        c.extend(by: 15 * 60)
        expectEqual(c.endDate, end.addingTimeInterval(900), "extend: bitiş 15 dk ileri")
        expectEqual(c.duration?.seconds, 2_700, "extend: toplam süre 45 dk")

        c.stop()
        c.start(.indefinite)
        expectNil(c.endDate, "extend: süresiz oturumun bitişi yok")
        c.extend(by: 600)
        expect(c.endDate != nil, "extend: süresiz oturum süreli oldu")
        expect((c.remaining ?? 0) > 590, "extend: kalan yaklaşık 10 dk")
        c.extend(by: -5)
        expect((c.remaining ?? 0) < 700, "extend: negatif uzatma yok sayılır")
        h.tearDown()
    }

    // Kapanış idempotent
    do {
        let h = SessionHarness(battery: battery(80))
        let c = h.controller!
        c.start(.oneHour)
        c.shutdown()
        c.shutdown()
        expectEqual(h.history.records.count, 1, "shutdown: çift çağrı tek kayıt")
        expectEqual(h.history.records.first?.endReason, .quit, "shutdown: bitiş sebebi quit")
        expect(!c.isOn, "shutdown: kapalı")
        h.tearDown()
    }

    // Pil eşiği: düşük pille başlamaz, çalışırken düşerse kapanır
    do {
        let h = SessionHarness(battery: battery(5))
        let c = h.controller!
        c.start(.oneHour)
        expect(!c.isOn, "battery: eşik altında başlamaz")
        expect(h.history.records.isEmpty, "battery: boş geçmiş kaydı oluşmaz")
        expect(c.lastError != nil, "battery: kullanıcıya sebep bildirilir")

        h.battery = battery(5, onBattery: false)
        c.start(.oneHour)
        expect(c.isOn, "battery: güç bağlıyken başlar")

        h.battery = battery(4)
        c.refreshBattery()
        expect(!c.isOn, "battery: pile geçip eşik altına inince kapandı")
        expectEqual(h.history.records.first?.endReason, .battery, "battery: bitiş sebebi")
        expectEqual(h.history.records.first?.batteryPercentAtEnd, 4, "battery: bitişteki pil")
        h.tearDown()
    }

    // Kapak modu: aç, oturumu başlatır; durdurunca SleepDisabled geri alınır
    do {
        let h = SessionHarness(battery: battery(90, onBattery: false))
        let c = h.controller!
        var result: Result<Void, Error>?
        c.setLidModeAsync(true) { result = $0 }
        h.spin { result != nil }
        if case .success = result {} else { expect(false, "lid: açma başarılı olmalı") }
        expect(c.lidMode, "lid: kapak modu açık")
        expect(c.isOn, "lid: oturum otomatik başladı")
        expect(h.lid.sleepDisabledValue, "lid: SleepDisabled 1")
        expect(h.history.active?.usedLid == true, "lid: geçmişte kapak işaretli")

        c.stop(reason: .user)
        expect(!c.lidMode, "lid: stop kapak modunu kapattı")
        expect(!h.lid.sleepDisabledValue, "lid: SleepDisabled geri alındı")
        expect(h.history.records.first?.usedLid == true, "lid: kayıtta kapak kullanıldı")
        h.tearDown()
    }

    // Kapak pil koruması oturumu kapatır
    do {
        let h = SessionHarness(battery: battery(90, onBattery: false))
        let c = h.controller!
        var done = false
        c.setLidModeAsync(true) { _ in done = true }
        h.spin { done }
        h.battery = battery(15)
        c.refreshBattery()
        expect(!c.lidMode, "lid floor: kapak modu kapandı")
        expect(!c.isOn, "lid floor: oturum kapandı")
        expectEqual(h.history.records.first?.endReason, .lidBattery, "lid floor: bitiş sebebi")
        h.tearDown()
    }

    // Pil eşiğinin altında kapak modu açılmaz
    do {
        let h = SessionHarness(battery: battery(5))
        let c = h.controller!
        var result: Result<Void, Error>?
        c.setLidModeAsync(true) { result = $0 }
        h.spin { result != nil }
        if case .failure = result {} else { expect(false, "lid: düşük pilde açılmamalı") }
        expect(!c.lidMode, "lid: düşük pilde kapalı")
        expect(h.lid.setCalls.isEmpty, "lid: pmset hiç çağrılmadı")
        h.tearDown()
    }

    // Kapak modu kapatılamazsa durum korunur ve hata bildirilir
    do {
        let h = SessionHarness(battery: battery(90, onBattery: false))
        let c = h.controller!
        var done = false
        c.setLidModeAsync(true) { _ in done = true }
        h.spin { done }
        h.lid.failTurningOff = true
        c.stop(reason: .user, allowLidPrompt: false)
        expect(!c.isOn, "lid fail: oturum kapandı")
        expect(c.lidMode, "lid fail: kapak modu hâlâ açık görünür")
        expect(c.lastError != nil, "lid fail: hata gösterilir")
        h.lid.failTurningOff = false
        h.tearDown()
    }

    // Uzak erişim modu
    do {
        let h = SessionHarness(battery: battery(80))
        let c = h.controller!
        h.settings.keepSessionUnlocked = true
        c.enterRemoteMode(lock: true)
        expect(c.isOn, "remote: oturum başlatıldı")
        expect(c.remoteBlankActive, "remote: karartma aktif")
        expect(c.remoteLocked, "remote: kilitli")
        expectEqual(h.remote.lockCalls, 1, "remote: kilit çağrıldı")
        expectEqual(h.remote.sleepCalls, 1, "remote: ekran uyutuldu")
        expect(!h.assertions.isUserActivityHeld, "remote: kilitliyken kullanıcı etkinliği bırakıldı")
        expect(h.history.active?.usedRemote == true, "remote: geçmişte işaretli")

        c.exitRemoteMode()
        expect(!c.remoteBlankActive, "remote: karartma kapandı")
        expectEqual(h.remote.wakeCalls, 1, "remote: ekran uyandırıldı")
        expect(c.isOn, "remote: oturum açık kalır")

        c.enterRemoteMode(lock: false)
        expectEqual(h.remote.lockCalls, 1, "remote: kilitsiz modda kilit yok")
        expect(!h.assertions.isUserActivityHeld, "remote: kilitsiz karartmada da kullanıcı etkinliği yok (ekranı yakar)")
        let declaresDuringBlackout = h.assertions.declareCount
        h.settings.keepDisplayAwake.toggle()
        h.settings.keepDisplayAwake.toggle()
        expectEqual(h.assertions.declareCount, declaresDuringBlackout, "remote: ayar değişimi karartmada etkinlik bildirmez")
        c.exitRemoteMode()
        expect(h.assertions.isUserActivityHeld, "remote: çıkınca oturum açık kalsın geri gelir")
        c.enterRemoteMode(lock: false)
        c.stop()
        expectEqual(h.remote.wakeCalls, 3, "remote: stop ekranı uyandırır")
        h.tearDown()
    }

    // Toggle varsayılan süreyi kullanır
    do {
        let h = SessionHarness(battery: battery(80)) { settings in
            settings.defaultDuration = .fifteenMinutes
        }
        let c = h.controller!
        c.toggle()
        expectEqual(c.duration, .fifteenMinutes, "toggle: varsayılan süre")
        c.toggle()
        expect(!c.isOn, "toggle: ikinci basış kapatır")
        h.tearDown()
    }
}

/// DeepSeek incelemesinin regresyon testleri: dış komutlar parola istemez, URL süreleri sınırlı.
func runExternalCommandChecks() {
    // Süre üst sınırı
    let eight: TimeInterval = 8 * 3600
    expectEqual(SessionController.capped(.indefinite, to: eight), PusuDuration(seconds: eight), "cap: süresiz 8 saate iner")
    expectEqual(SessionController.capped(PusuDuration(minutes: 600), to: eight), PusuDuration(seconds: eight), "cap: 10 saat 8 saate iner")
    expectEqual(SessionController.capped(.oneHour, to: eight), .oneHour, "cap: 1 saat aynen")
    expectEqual(SessionController.capped(.indefinite, to: nil), .indefinite, "cap: sınırsız kaynak aynen")

    // Dışarıdan toggle/stop: kapak modu kapatılırken parola istenmez
    do {
        let h = SessionHarness(battery: battery(90, onBattery: false))
        let c = h.controller!
        var done = false
        c.setLidModeAsync(true, allowPrompt: false) { _ in done = true }
        h.spin { done }
        expectEqual(h.lid.setCalls.last?.allowPrompt, false, "external: lid açma parola istemez")
        c.toggle(allowLidPrompt: false)
        expect(!c.isOn, "external: toggle kapattı")
        expectEqual(h.lid.setCalls.last?.enabled, false, "external: kapak kapatıldı")
        expectEqual(h.lid.setCalls.last?.allowPrompt, false, "external: kapatırken parola istemez")
        h.tearDown()
    }

    // URL toggle süresiz varsayılanı 8 saatle sınırlar
    do {
        let h = SessionHarness(battery: battery(90, onBattery: false))
        let c = h.controller!
        c.toggle(allowLidPrompt: false, maxDuration: eight)
        expectEqual(c.duration?.seconds, eight, "url toggle: süresiz yerine 8 saat")
        h.tearDown()
    }

    // Orijinal SleepDisabled 1 ise kapak modunu kapatmak hata sayılmaz
    do {
        let h = SessionHarness(battery: battery(90, onBattery: false))
        let c = h.controller!
        h.lid.restoreValue = true
        var opened = false
        c.setLidModeAsync(true) { _ in opened = true }
        h.spin { opened }
        var result: Result<Void, Error>?
        c.setLidModeAsync(false) { result = $0 }
        h.spin { result != nil }
        if case .success = result {} else { expect(false, "original 1: kapatma başarılı olmalı") }
        expect(!c.lidMode, "original 1: kapak modu kapalı görünür")
        expect(c.sleepDisabledActive, "original 1: gerçek değer (1) gösterilir")
        h.tearDown()
    }
}

func runURLStrictnessChecks() {
    func url(_ string: String) -> PusuCommand? {
        URL(string: string).flatMap(CommandParser.parse(url:))
    }
    expectNil(url("pusu://on?minutes=0"), "url: sıfır süre reddedilir")
    expectNil(url("pusu://on?minutes=-5"), "url: negatif süre reddedilir")
    expectNil(url("pusu://on?minutes=abc"), "url: metin süre reddedilir")
    expectNil(url("pusu://on?minutes=999999999999"), "url: devasa süre reddedilir")
    expectNil(url("pusu://on?minutes="), "url: boş süre reddedilir")
    expectEqual(url("pusu://on"), .on(minutes: nil), "url: süresiz istek (uygulama 8 saatle sınırlar)")
}
