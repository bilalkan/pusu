import Foundation
import PusuCore

func runRemoteModeChecks() {
    // Varsayılan: kilitle ve ekranı uyut; kimse izlemiyorken ekran tutulmaz
    do {
        let h = SessionHarness(battery: battery(80))
        let c = h.controller!
        c.enterRemoteMode(lock: true)
        expect(c.remoteLocked, "vnc: kilitli")
        expectEqual(h.remote.sleepCalls, 1, "vnc: ekran uyutuldu")
        expect(c.remoteDisplaySlept, "vnc: uyku durumu")
        expect(!c.remotePanelDark, "vnc: karartma yok")
        expect(!h.assertions.isDisplayHeld, "vnc: bağlantı yokken ekran açık tutulmaz")
        expect(h.clients.started, "vnc: Tern izleyicisi başladı")
        expectEqual(h.remote.rememberCalls, 1, "vnc: seviyeler uyutmadan önce hatırlandı")

        // Tern bağlandı: ekran karanlık uyanır ve açık tutulur
        h.clients.attach()
        expect(c.remotePanelDark, "vnc: bağlantıda panel karanlık")
        expectEqual(h.remote.wakeCalls, 1, "vnc: bağlantıda ekran uyandı")
        expect(h.assertions.isDisplayHeld, "vnc: bağlantıda ekran açık tutulur")

        // 30 sn kimse izlemezse (yalnızca terminal) yeniden uyur ve kilitlenir
        let start = Date()
        c.processTick(now: start.addingTimeInterval(10))
        expect(c.remotePanelDark, "vnc: 10 sn sonra hâlâ karanlık")
        h.remote.unlock()
        c.processTick(now: start.addingTimeInterval(31))
        expect(!c.remotePanelDark, "vnc: izlenmeyince karartma bitti")
        expectEqual(h.remote.sleepCalls, 2, "vnc: izlenmeyince uyutuldu")
        expectEqual(h.remote.lockCalls, 2, "vnc: kilit açılmışsa yeniden kilitlendi")
        expect(!h.assertions.isDisplayHeld, "vnc: ekran bırakıldı")
        expect(h.eventLog.messages.contains("Nobody viewed the screen"), "vnc: günlük")

        // Yeni bağlantı + izleme: bağlantı sürdükçe karanlık kalır (sekme değişse bile)
        h.clients.attach()
        h.remote.watched = true
        c.processTick(now: start.addingTimeInterval(40))
        h.remote.watched = false
        c.processTick(now: start.addingTimeInterval(40 + 120))
        expect(c.remotePanelDark, "vnc: izlendikten sonra 2 dk izlenmese de karanlık açık")
        expect(h.remote.maintainCalls >= 2, "vnc: karartma korunuyor")

        // Tern ayrılınca hemen uyur
        h.clients.detach()
        expect(!c.remotePanelDark, "vnc: ayrılınca karartma bitti")
        expectEqual(h.remote.sleepCalls, 3, "vnc: ayrılınca uyutuldu")

        c.exitRemoteMode()
        expectEqual(h.remote.forgetCalls, 1, "vnc: çıkışta seviyeler unutuldu")
        expect(!h.clients.started, "vnc: izleyici durdu")
        expect(!c.remoteBlankActive, "vnc: mod bitti")
        h.tearDown()
    }

    // İzlendikten sonra 10 dakika izlenmezse uyur
    do {
        let h = SessionHarness(battery: battery(80))
        let c = h.controller!
        c.enterRemoteMode(lock: false)
        h.clients.attach()
        h.remote.watched = true
        let start = Date()
        c.processTick(now: start)
        h.remote.watched = false
        c.processTick(now: start.addingTimeInterval(SessionController.remoteViewedTimeout - 5))
        expect(c.remotePanelDark, "10 dk: süre dolmadan karanlık")
        c.processTick(now: start.addingTimeInterval(SessionController.remoteViewedTimeout + 1))
        expect(!c.remotePanelDark, "10 dk: süre dolunca uyudu")
        expectEqual(h.remote.lockCalls, 0, "10 dk: kilitsiz modda kilitlenmez")
        c.exitRemoteMode()
        h.tearDown()
    }

    // Ekran uyurken biri izlemeye başlarsa (Apple Ekran Paylaşımı) panel kararır
    do {
        let h = SessionHarness(battery: battery(80))
        let c = h.controller!
        c.enterRemoteMode(lock: true)
        h.remote.watched = true
        c.processTick()
        expect(c.remotePanelDark, "ekran paylaşımı: izlenince karardı")
        expect(h.assertions.isDisplayHeld, "ekran paylaşımı: ekran açık tutulur")
        c.exitRemoteMode()
        h.tearDown()
    }

    // Mod, ekran izlenirken başlatıldıysa doğrudan karanlık (uyutulmaz)
    do {
        let h = SessionHarness(battery: battery(80))
        h.remote.watched = true
        let c = h.controller!
        c.enterRemoteMode(lock: true)
        expect(c.remotePanelDark, "uzaktan başlatma: karanlık")
        expectEqual(h.remote.sleepCalls, 0, "uzaktan başlatma: uyutulmadı")
        c.exitRemoteMode()
        h.tearDown()
    }

    // Başka bir cihazın uzun süreli bağlantısı varken yeni bağlantı da ekranı uyandırır
    do {
        let h = SessionHarness(battery: battery(80))
        let c = h.controller!
        c.enterRemoteMode(lock: true)
        h.clients.attach()
        c.processTick(now: Date().addingTimeInterval(31))
        expect(!c.remotePanelDark, "iki cihaz: ilki izlemeyince uyudu")
        h.clients.attach()
        expect(c.remotePanelDark, "iki cihaz: ikinci bağlantı uyandırdı")
        c.exitRemoteMode()
        h.tearDown()
    }

    // "Ekranı hiç uyutma": hep karanlık, ayrılınca ve izlenmeyince de uyutulmaz
    do {
        let h = SessionHarness(battery: battery(80)) { settings in
            settings.remoteKeepsDisplayOn = true
        }
        let c = h.controller!
        c.enterRemoteMode(lock: true)
        expect(c.remotePanelDark, "hep açık: karanlık")
        expectEqual(h.remote.sleepCalls, 0, "hep açık: uyutulmadı")
        expect(h.assertions.isDisplayHeld, "hep açık: ekran tutulur")
        h.clients.attach()
        h.clients.detach()
        c.processTick(now: Date().addingTimeInterval(3_600))
        expectEqual(h.remote.sleepCalls, 0, "hep açık: hiç uyutulmadı")
        expect(c.remotePanelDark, "hep açık: karanlık sürüyor")
        c.exitRemoteMode()
        expect(!c.remotePanelDark, "hep açık: çıkışta geri yüklendi")
        h.tearDown()
    }

    // Karartma başarısızsa günlüğe yazılır, mod bozulmaz
    do {
        let h = SessionHarness(battery: battery(80))
        h.remote.darkenResult = false
        let c = h.controller!
        c.enterRemoteMode(lock: true)
        h.clients.attach()
        expect(!c.remotePanelDark, "karartma hatası: karanlık değil")
        c.processTick(now: Date().addingTimeInterval(6))
        expect(h.eventLog.messages.contains("Display could not be darkened"), "karartma hatası: günlük")
        expect(c.remoteBlankActive, "karartma hatası: mod sürüyor")
        // İlk denemede uyuyan ekran karartılamaz, uyanınca karartılır
        h.remote.darkenResult = true
        c.processTick(now: Date().addingTimeInterval(7))
        expect(c.remotePanelDark, "karartma: uyanınca tamamlandı")
        c.exitRemoteMode()
        h.tearDown()
    }

    // Karartma tamamlanmadan Tern ayrılırsa da ekran yeniden uyutulur
    do {
        let h = SessionHarness(battery: battery(80))
        h.remote.darkenResult = false
        let c = h.controller!
        c.enterRemoteMode(lock: true)
        h.clients.attach()
        h.clients.detach()
        expectEqual(h.remote.sleepCalls, 2, "bekleyen karartma: ayrılınca uyutuldu")
        expectEqual(h.remote.restoreCalls, 1, "bekleyen karartma: kaydedilen parlaklık geri yüklendi")
        c.exitRemoteMode()
        h.tearDown()
    }

    // Kapak kapalı + kapak modu: sanal ekran; kapak açılınca kaldırılır
    do {
        let h = SessionHarness(battery: battery(80))
        let c = h.controller!
        h.lid.sleepDisabledValue = true
        c.refreshLidState()
        expect(c.lidMode, "sanal: kapak modu açık")
        c.enterRemoteMode(lock: true)
        h.lidClosed = true
        c.processTick(); c.processTick()
        expect(c.remoteVirtualDisplay, "sanal: kapak kapanınca sanal ekran")
        expectEqual(h.remote.virtualShowCalls, 1, "sanal: bir kez açıldı")
        expect(h.assertions.isDisplayHeld, "sanal: ekran açık tutulur")
        h.clients.attach()
        expect(!c.remotePanelDark, "sanal: kapak kapalıyken karartma gerekmez")
        h.clients.detach()
        c.processTick(now: Date().addingTimeInterval(3_600))
        expectEqual(h.remote.sleepCalls, 0, "sanal: kapak modunda ekran hiç uyutulmaz")
        h.lidClosed = false
        c.processTick(); c.processTick()
        expect(!c.remoteVirtualDisplay, "sanal: kapak açılınca kaldırıldı")
        expect(!h.remote.virtualDisplayActive, "sanal: ekran nesnesi bırakıldı")
        expect(!c.remoteBlankActive, "sanal: kapağı açmak modu bitirir (Mac başında biri var)")
        expect(c.isOn, "sanal: oturum açık kalır")
        h.tearDown()
    }

    // Kapak kapanmadan önce uyandırılmış ekranın zamanlayıcısı, kapak açılınca uyutmaz
    do {
        let h = SessionHarness(battery: battery(80))
        let c = h.controller!
        h.lid.sleepDisabledValue = true
        c.refreshLidState()
        h.remote.darkenResult = false
        c.enterRemoteMode(lock: true)
        h.clients.attach()
        expect(h.assertions.isDisplayHeld, "uyanma: karartma tutmasa da ekran açık tutulur")
        h.lidClosed = true
        c.processTick(); c.processTick()
        expect(c.remoteVirtualDisplay, "uyanma: kapak kapanınca sanal ekran")
        c.processTick(now: Date().addingTimeInterval(120))
        expectEqual(h.remote.sleepCalls, 0, "uyanma: eski zamanlayıcı ekranı uyutmadı")
        c.exitRemoteMode()
        h.tearDown()
    }

    // Kapak modu açıkken kapak açık: ekran uyutulmaz, karanlık tutulur (kapak uyanık ekranla
    // kapanmalı ki kilit ekranı sanal ekrana geçsin)
    do {
        let h = SessionHarness(battery: battery(80))
        h.lid.sleepDisabledValue = true
        let c = h.controller!
        c.refreshLidState()
        c.enterRemoteMode(lock: true)
        expectEqual(h.remote.sleepCalls, 0, "kapak modu: uyutulmadı")
        expect(c.remotePanelDark, "kapak modu: karanlık")
        expect(h.assertions.isDisplayHeld, "kapak modu: ekran açık tutulur")
        c.processTick(now: Date().addingTimeInterval(3_600))
        expect(c.remotePanelDark, "kapak modu: izlenmese de karanlık kalır")
        c.exitRemoteMode()
        h.tearDown()
    }

    // Mod kapak kapalıyken başlarsa doğrudan sanal ekran
    do {
        let h = SessionHarness(battery: battery(80))
        h.lid.sleepDisabledValue = true
        h.lidClosed = true
        let c = h.controller!
        c.refreshLidState()
        c.enterRemoteMode(lock: true)
        expect(c.remoteVirtualDisplay, "sanal: kapalı kapakta doğrudan")
        expectEqual(h.remote.sleepCalls, 0, "sanal: uyutulmadı")
        c.exitRemoteMode()
        expect(!h.remote.virtualDisplayActive, "sanal: çıkışta kaldırıldı")
        h.tearDown()
    }

    // Kapak kapalı ama kapak modu kapalı: sanal ekran açılmaz
    do {
        let h = SessionHarness(battery: battery(80))
        let c = h.controller!
        c.enterRemoteMode(lock: true)
        h.lidClosed = true
        c.processTick(); c.processTick()
        expectEqual(h.remote.virtualShowCalls, 0, "sanal: kapak modu yokken açılmaz")
        c.exitRemoteMode()
        h.tearDown()
    }

    // Stop ve çıkış her şeyi geri alır
    do {
        let h = SessionHarness(battery: battery(80)) { settings in
            settings.remoteKeepsDisplayOn = true
        }
        let c = h.controller!
        c.enterRemoteMode(lock: true)
        c.stop()
        expectEqual(h.remote.restoreCalls, 1, "stop: geri yüklendi")
        expect(!h.clients.started, "stop: izleyici durdu")
        c.enterRemoteMode(lock: true)
        c.shutdown()
        expectEqual(h.remote.restoreCalls, 2, "çıkış: geri yüklendi")
        h.tearDown()
    }

    // Kilit ekranında Mac'in kendi klavyesi/trackpad'i: mod biter; öncesi ve ilk 3 sn sayılmaz
    do {
        let h = SessionHarness(battery: battery(80))
        h.remote.lastLocalInput = Date().addingTimeInterval(-60)
        let c = h.controller!
        c.enterRemoteMode(lock: true)
        h.clients.attach()
        c.processTick()
        expect(c.remoteBlankActive, "yerel aygıt: eski dokunuş sayılmadı")
        h.remote.lastLocalInput = Date().addingTimeInterval(1)
        c.processTick()
        expect(c.remoteBlankActive, "yerel aygıt: modu başlatan tıklamanın devamı sayılmadı")
        h.remote.lastLocalInput = Date().addingTimeInterval(10)
        c.processTick()
        expect(!c.remoteBlankActive, "yerel aygıt: dokunuş modu bitirdi")
        expectEqual(h.remote.restoreCalls, 1, "yerel aygıt: ekran geri geldi")
        h.tearDown()
    }

    // Yerel dokunuş kaydının adı
    expect(RemoteController.isLocalInputAssertion("com.apple.iohideventsystem.queue.tickle serviceID:10000092a service:AppleHIDKeyboardEventDriverV2 product:Apple Internal Keyboard / Trackpad eventType:3"), "kayıt: dahili klavye")
    expect(RemoteController.isLocalInputAssertion("com.apple.iohideventsystem.queue.tickle serviceID:10000094d service:AppleMultitouchDevice product:Apple Internal Keyboard / Trackpad eventType:11"), "kayıt: dahili trackpad")
    expect(!RemoteController.isLocalInputAssertion("com.apple.iohideventsystem.queue.tickle.nxevent service:IOHIDSystem pid:36503 process:tern"), "kayıt: Tern sayılmaz")
    expect(!RemoteController.isLocalInputAssertion("com.apple.iohideventsystem.queue.tickle serviceID:0 service:(null) product:(null) eventType:29"), "kayıt: aygıtsız sayılmaz")
    expect(!RemoteController.isLocalInputAssertion("Pusu keeps the session unlocked"), "kayıt: Pusu'nun kendi kaydı sayılmaz")

    // Mac başında tıklama: mod biter
    do {
        let h = SessionHarness(battery: battery(80))
        let c = h.controller!
        c.enterRemoteMode(lock: true)
        h.clients.attach()
        c.localInputDetected()
        expect(!c.remoteBlankActive, "yerel: mod bitti")
        expectEqual(h.remote.restoreCalls, 1, "yerel: parlaklık geri geldi")
        expect(c.isOn, "yerel: oturum açık kalır")
        c.localInputDetected()
        h.tearDown()
    }
}

func runTernWatcherChecks() {
    // Satır ayrıştırma (gerçek Tern biçimi)
    let attached = "2026-11-21T14:36:10.957+03:00 36503  INFO               main stencil_tern: daemon client attached id=96 kind=Remote"
    let detached = "2026-11-21T14:37:10.957+03:00 36503  INFO               main stencil_tern: daemon client detached id=96 kind=Remote"
    let window = "2026-11-17T17:58:36.727+03:00 34393  INFO               main stencil_tern: daemon client attached id=1 kind=Window"
    let started = "2026-11-17T17:58:36.160+03:00 34393  INFO main stencil_tern: daemon started path=/x/daemon.sock handed=true"
    expectEqual(TernClientWatcher.parse(attached), .attached(96), "tern: bağlandı")
    expectEqual(TernClientWatcher.parse(detached), .detached(96), "tern: ayrıldı")
    expectNil(TernClientWatcher.parse(window), "tern: yerel pencere sayılmaz")
    expectEqual(TernClientWatcher.parse(started), .daemonStarted, "tern: servis başladı")
    expectNil(TernClientWatcher.parse("daemon client attached id=abc kind=Remote"), "tern: bozuk numara")
    expectNil(TernClientWatcher.parse("başka bir satır"), "tern: ilgisiz satır")

    let clients = TernClientWatcher.apply([.attached(1), .attached(2), .detached(1)], to: [])
    expectEqual(clients, [2], "tern: açık bağlantılar")
    expectEqual(TernClientWatcher.apply([.daemonStarted], to: [2, 3]), [], "tern: servis yeniden başlayınca sıfırlanır")

    // Dosya izleme: geçmişten açık bağlantı, yeni satırlar, döndürme
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pusu-tern-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("tern-daemon.log")
    func append(_ line: String) {
        let handle = try! FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write((line + "\n").data(using: .utf8)!)
        try? handle.close()
    }
    FileManager.default.createFile(atPath: url.path, contents: (attached + "\n").data(using: .utf8))
    let watcher = TernClientWatcher(url: url, pollInterval: 60)
    var changes: [Bool] = []
    watcher.onClientEvent = { changes.append($0) }
    watcher.start()
    expect(watcher.isConnected, "tern dosya: açık bağlantı geçmişten bulundu")
    expect(changes.isEmpty, "tern dosya: başlangıçta bildirim yok")

    append(detached)
    watcher.poll()
    expect(!watcher.isConnected, "tern dosya: ayrıldı")
    expectEqual(changes, [false], "tern dosya: ayrılma bildirildi")

    // Yarım satır: ikinci yarısı gelene kadar sayılmaz
    let handle = try! FileHandle(forWritingTo: url)
    handle.seekToEndOfFile()
    handle.write("2026-11-21T15:00:00.000+03:00 1 INFO main stencil_tern: daemon client att".data(using: .utf8)!)
    try? handle.close()
    watcher.poll()
    expect(!watcher.isConnected, "tern dosya: yarım satır sayılmadı")
    append("ached id=97 kind=Remote")
    watcher.poll()
    expect(watcher.isConnected, "tern dosya: satır tamamlanınca bağlandı")

    // Döndürme: dosya yeniden oluşturuldu
    try? FileManager.default.removeItem(at: url)
    FileManager.default.createFile(atPath: url.path, contents: (started + "\n").data(using: .utf8))
    watcher.poll()
    expect(!watcher.isConnected, "tern dosya: yeni dosyada servis başladı, bağlantı yok")

    watcher.stop()
    expectEqual(changes, [false, true, false], "tern dosya: bütün değişiklikler")

    // Dosya yoksa sessizce çalışır
    let missing = TernClientWatcher(url: directory.appendingPathComponent("yok.log"), pollInterval: 60)
    missing.start()
    missing.poll()
    expect(!missing.isConnected, "tern: dosya yoksa bağlantı yok")
    missing.stop()
    try? FileManager.default.removeItem(at: directory)
}
