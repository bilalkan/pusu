import CoreGraphics
import Foundation
import IOKit

/// "Uygulamaları aktif tut": Teams, ekran koruyucu gibi "boşta" kararını IOHIDSystem'in
/// `HIDIdleTime` sayacına göre veren uygulamalar için. Güç kayıtları (uyku engeli, "kullanıcı etkin"
/// bildirimi) bu sayacı sıfırlamaz; gönderilmiş bir fare olayı sıfırlar.
///
/// İzin gerekmez: izinsiz gönderilen olay uygulamalara ulaşmaz ama `HIDIdleTime`'ı sıfırlar (bu Mac'te
/// ölçüldü). Caffeine'in "Keep apps active" seçeneği de aynı şeyi izin istemeden yapar. Erişilebilirlik
/// izni verilirse olay oturum sayacını (`CGEventSource`) da sıfırlar; Pusu bunu istemez.
public protocol ActivityPosting: AnyObject {
    /// Son girdiden beri geçen süre (`HIDIdleTime`; yerel ya da uzaktan, gönderilmiş olaylar dahil).
    func secondsSinceLastInput() -> TimeInterval
    /// İmleci yerinde "oynatan" bir fare olayı gönderir. Ekran uyuyorsa göndermez (uyandırırdı).
    @discardableResult
    func nudge() -> Bool
}

public final class SyntheticActivity: ActivityPosting {
    public init() {}

    public func secondsSinceLastInput() -> TimeInterval {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber
        else { return 0 }
        return value.doubleValue / 1_000_000_000
    }

    @discardableResult
    public func nudge() -> Bool {
        guard CGDisplayIsAsleep(CGMainDisplayID()) == 0,
              let position = CGEvent(source: nil)?.location,
              let event = CGEvent(
                  mouseEventSource: CGEventSource(stateID: .hidSystemState),
                  mouseType: .mouseMoved,
                  mouseCursorPosition: position,
                  mouseButton: .left
              )
        else { return false }
        // Sıfır piksellik hareket: imleç yerinden oynamaz, ama boşta süresi sıfırlanır.
        event.post(tap: .cghidEventTap)
        return true
    }
}

public enum AppActivityPolicy {
    /// Kontrol aralığı (saniye). Teams ~5 dakikada "Uzakta" yapar; bir dakika rahat bir pay.
    public static let checkInterval = 30
    /// Kullanıcı bu kadar süredir hiçbir şeye dokunmadıysa olay gönderilir; çalışırken araya girilmez.
    public static let idleThreshold: TimeInterval = 50
}
