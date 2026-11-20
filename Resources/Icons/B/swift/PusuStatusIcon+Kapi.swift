// PusuStatusIcon+Kapi.swift — Pusu menü çubuğu ikonu, ALTERNATİF konsept: "aralık kapıdan sızan ışık"
//
// Bu dosya v3'teki PusuStatusIcon.swift ile AYNI API'yi sunar (PusuIconState, PusuStatusIcon(button:), update(_:)).
// İkisinden yalnızca birini projeye ekle; ikisi birlikte derlenmez (aynı tip adları).
//
// Mimari:
//   • Kapı glifi            → template NSImage (rengi sistem verir)
//   • Amber ışık yarığı      → ayrı renkli katman (PusuSlitView), status butonunun effectiveAppearance'ına göre
//                              açık zeminde #C77700, koyu zeminde #FFC24A
//   • Süreli mod             → yarığın kalan süre kadar kısmı tam renk (alttan yukarı), geçen kısım %30
//
// Geometri pusu-kapi-menubar-*.svg ile birebir aynıdır (18×18 pt, y aşağı doğru).
// Not: Linux ortamında yazıldı, derlenmedi; ilk derlemede küçük düzeltme gerekebilir.

import AppKit

// MARK: - Durumlar

enum PusuIconState: Equatable {
    case off                          // kapı kapalı, yarık yok
    case awake                        // kapı aralık, yarık yanıyor
    case timed(remaining: Double)     // 0…1 kalan oran; yarık alttan yukarı doluluk
    case lidClosed                    // kapak kapalı modu: kapı panelinin alt yarısı dolu
    case vncLock                      // VNC karartma/kilit: tüm kapı dolu

    var showsLight: Bool { self != .off }
}

// MARK: - Glif

enum PusuGlyph {
    static let size = NSSize(width: 18, height: 18)
    static let lineWidth: CGFloat = 1.2
    static let frameRect = NSRect(x: 4.6, y: 2.3, width: 8.8, height: 13.4)
    static let doorEdgeX: CGFloat = 10.6
    /// Işık yarığı (glif koordinatı, y aşağı)
    static let slitRect = NSRect(x: 11.3, y: 3.0, width: 1.4, height: 12.0)

    static func templateImage(for state: PusuIconState) -> NSImage {
        let img = NSImage(size: size, flipped: true) { _ in
            NSColor.black.set()
            let frame = NSBezierPath(roundedRect: frameRect, xRadius: 0.6, yRadius: 0.6)
            frame.lineWidth = lineWidth

            switch state {
            case .off:
                frame.stroke()
                knob(at: NSPoint(x: 11.7, y: 9.3)).fill()

            case .awake, .timed:
                frame.stroke(); doorEdge().stroke()
                knob(at: NSPoint(x: 9.2, y: 9.3)).fill()

            case .lidClosed:
                frame.stroke(); doorEdge().stroke()
                knob(at: NSPoint(x: 9.2, y: 9.3)).fill()
                NSBezierPath(rect: NSRect(x: 4.6, y: 10.4, width: 6.0, height: 5.3)).fill()

            case .vncLock:
                frame.fill(); frame.stroke()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = accessibilityLabel(for: state)
        return img
    }

    private static func doorEdge() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: doorEdgeX, y: frameRect.minY))
        p.line(to: NSPoint(x: doorEdgeX, y: frameRect.maxY))
        p.lineWidth = lineWidth
        return p
    }

    private static func knob(at c: NSPoint) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: c.x - 0.7, y: c.y - 0.7, width: 1.4, height: 1.4))
    }

    static func accessibilityLabel(for state: PusuIconState) -> String {
        switch state {
        case .off: return "Pusu: kapalı"
        case .awake: return "Pusu: uyanık"
        case .timed: return "Pusu: süreli uyanık"
        case .lidClosed: return "Pusu: kapak kapalı modu"
        case .vncLock: return "Pusu: VNC kilit modu"
        }
    }
}

// MARK: - Amber ışık yarığı katmanı

final class PusuSlitView: NSView {
    static let amberOnLight = NSColor(srgbRed: 0xC7/255, green: 0x77/255, blue: 0x00/255, alpha: 1) // #C77700
    static let amberOnDark  = NSColor(srgbRed: 0xFF/255, green: 0xC2/255, blue: 0x4A/255, alpha: 1) // #FFC24A

    /// 0…1; 1 = tam yarık
    var fraction: Double = 1 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let amber = isDark ? Self.amberOnDark : Self.amberOnLight
        let f = CGFloat(max(0, min(1, fraction)))
        if f < 1 {
            amber.withAlphaComponent(0.3).setFill()
            NSBezierPath(rect: bounds).fill()
        }
        amber.setFill()
        let h = bounds.height * f
        NSBezierPath(rect: NSRect(x: bounds.minX, y: bounds.maxY - h, width: bounds.width, height: h)).fill() // alttan yukarı
    }
}

// MARK: - Status item bağlayıcı (v3 ile aynı API)

final class PusuStatusIcon {
    private weak var button: NSStatusBarButton?
    private let slit = PusuSlitView()
    private(set) var state: PusuIconState = .off

    init(button: NSStatusBarButton) {
        self.button = button
        button.imagePosition = .imageOnly
        button.addSubview(slit)
        update(.off)
    }

    func update(_ newState: PusuIconState) {
        state = newState
        guard let button else { return }
        button.image = PusuGlyph.templateImage(for: newState)
        button.setAccessibilityLabel(PusuGlyph.accessibilityLabel(for: newState))
        slit.isHidden = !newState.showsLight
        if case .timed(let remaining) = newState { slit.fraction = remaining } else { slit.fraction = 1 }
        layoutSlit()
    }

    /// Buton boyutu değişirse tekrar çağır.
    func layoutSlit() {
        guard let button, let cell = button.cell else { return }
        let img = cell.imageRect(forBounds: button.bounds)
        let sx = img.width / PusuGlyph.size.width, sy = img.height / PusuGlyph.size.height
        let r = PusuGlyph.slitRect
        let x = img.minX + r.minX * sx
        let yTop = button.isFlipped ? img.minY + r.minY * sy : img.maxY - r.maxY * sy
        slit.frame = NSRect(x: x, y: yTop, width: r.width * sx, height: r.height * sy)
        slit.needsDisplay = true
    }
}

// Kullanım: v3 ile aynı
// let icon = PusuStatusIcon(button: statusItem.button!)
// icon.update(.awake); icon.update(.timed(remaining: 0.6)); icon.update(.off)
