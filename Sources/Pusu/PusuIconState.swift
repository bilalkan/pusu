import AppKit
import PusuCore

enum IconConcept: String {
    case keyhole = "A"
    case door = "B"

    /// Tek noktadan konsept seçimi.
    /// Varsayılan A (keyhole). Build sırasında Info.plist'e
    /// `PusuIconConcept = A|B` yazılarak değiştirilebilir.
    static var active: IconConcept {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "PusuIconConcept") as? String,
           let concept = IconConcept(rawValue: raw.uppercased()) {
            return concept
        }
        return .keyhole
    }

    var displayName: String {
        switch self {
        case .keyhole: return L("A · Gözetleme Deliği", "A · Keyhole")
        case .door: return L("B · Aralık Kapı", "B · Ajar Door")
        }
    }
}

protocol PusuStatusIconProtocol: AnyObject {
    func update(_ state: PusuIconState)
    func layoutOverlay()
}
