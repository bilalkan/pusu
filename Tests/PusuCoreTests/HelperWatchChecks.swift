import Foundation
import PusuCore

func runHelperWatchChecks() {
    func makeWatch(_ state: @escaping () -> HelperProbe) -> (HelperWatch, FakeEvents, URL) {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pusu-helper-watch-\(UUID().uuidString)")
            .appendingPathComponent("helper-expected")
        let events = FakeEvents()
        return (HelperWatch(markerURL: marker, events: events, probe: state), events, marker)
    }

    // Yardımcıyı hiç kurmamış biri uyarı görmez
    do {
        let (watch, events, _) = makeWatch { .notInstalled }
        expectEqual(watch.check(), .none, "helper watch: hiç kurulmamışsa sessiz")
        expectEqual(watch.check(), .none, "helper watch: ikinci kontrolde de sessiz")
        expect(!watch.expectsHelper, "helper watch: işaret yazılmaz")
        expect(events.messages.isEmpty, "helper watch: günlüğe bir şey yazılmaz")
    }

    // Çalışırken görülen yardımcı beklenir; kaybolunca önce doğrulanır, sonra bir kez bildirilir
    do {
        var state = HelperProbe.running
        let (watch, events, _) = makeWatch { state }
        expectEqual(watch.check(), .none, "helper watch: çalışıyor")
        expect(watch.expectsHelper, "helper watch: çalışırken görülünce işaret yazılır")

        state = .notInstalled
        expectEqual(watch.check(), .needsConfirmation, "helper watch: ilk başarısızlık doğrulama ister")
        expect(events.messages.isEmpty, "helper watch: doğrulanmadan günlüğe yazılmaz")
        expectEqual(watch.check(), .missing(.removed), "helper watch: ikinci başarısızlık bildirilir")
        expectEqual(events.messages.count, 1, "helper watch: tek günlük satırı")
        expect(events.messages.first?.contains("removed outside Pusu") == true, "helper watch: kaldırılma nedeni yazılır")
        expectEqual(watch.check(), .none, "helper watch: aynı sorun tekrar bildirilmez")
        expectEqual(watch.check(), .none, "helper watch: aynı sorun tekrar bildirilmez (2)")

        state = .running
        expectEqual(watch.check(), .restored, "helper watch: geri gelince bildirilir")
        expectEqual(events.messages.last, "Helper is running again", "helper watch: geri gelme günlüğe yazılır")
        expectEqual(watch.check(), .none, "helper watch: sonra sessiz")
    }

    // Kısa kesinti (kurulumda kickstart, yeniden başlatma) uyarı üretmez
    do {
        var state = HelperProbe.running
        let (watch, events, _) = makeWatch { state }
        _ = watch.check()
        state = .notResponding
        expectEqual(watch.check(), .needsConfirmation, "helper watch: kesinti doğrulama ister")
        state = .running
        expectEqual(watch.check(), .none, "helper watch: kesinti geçtiyse bildirim yok")
        state = .notResponding
        expectEqual(watch.check(), .needsConfirmation, "helper watch: sayaç sıfırlanmış")
        expectEqual(watch.check(), .missing(.notResponding), "helper watch: yanıt vermiyor bildirilir")
        expect(events.messages.last?.contains("not responding") == true, "helper watch: yanıt vermeme günlüğe yazılır")
    }

    // Pusu kurarken/kaldırırken kontrol edilmez; kullanıcının kaldırması uyarı üretmez
    do {
        var state = HelperProbe.running
        let (watch, events, marker) = makeWatch { state }
        _ = watch.check()
        watch.beginChange()
        state = .notInstalled
        expectEqual(watch.check(), .none, "helper watch: değişiklik sırasında sessiz")
        expectEqual(watch.check(), .none, "helper watch: değişiklik sırasında sessiz (2)")
        HelperWatch.setExpected(false, markerURL: marker)
        watch.endChange()
        expect(!watch.expectsHelper, "helper watch: kaldırınca işaret silinir")
        expectEqual(watch.check(), .none, "helper watch: kaldırıldıktan sonra sessiz")
        expectEqual(watch.check(), .none, "helper watch: kaldırıldıktan sonra sessiz (2)")
        expect(events.messages.isEmpty, "helper watch: kullanıcının kaldırması günlüğe sorun yazmaz")
    }

    // Bildirilmiş bir sorundan sonra yeniden kurulum durumu sıfırlar
    do {
        var state = HelperProbe.running
        let (watch, _, _) = makeWatch { state }
        _ = watch.check()
        state = .notInstalled
        _ = watch.check()
        expectEqual(watch.check(), .missing(.removed), "helper watch: kaldırılma bildirildi")
        watch.beginChange()
        state = .running
        watch.endChange()
        expectEqual(watch.check(), .none, "helper watch: Pusu'nun kurulumundan sonra 'geri geldi' tekrarı yok")
        state = .notInstalled
        expectEqual(watch.check(), .needsConfirmation, "helper watch: yeni kayıp yeniden izlenir")
    }

    // İşaret dosyası 0600
    do {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pusu-helper-watch-\(UUID().uuidString)")
            .appendingPathComponent("helper-expected")
        HelperWatch.setExpected(true, markerURL: marker)
        let mode = (try? FileManager.default.attributesOfItem(atPath: marker.path)[.posixPermissions] as? NSNumber)?.intValue
        expectEqual(mode, 0o600, "helper watch: işaret yalnızca kullanıcıya açık")
        HelperWatch.setExpected(false, markerURL: marker)
        expect(!FileManager.default.fileExists(atPath: marker.path), "helper watch: işaret silinir")
    }
}
