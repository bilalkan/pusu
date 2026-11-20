// PusuStatusIcon.swift — Pusu menü çubuğu ikonu (v3, jüri revizyonu)
//
// Mimari:
//   • Anahtar deliği glifi  → template NSImage (rengi sistem verir: vibrancy, ikincil ekran soluklaşması,
//                              "Reduce transparency" korunur)
//   • Amber nokta           → ayrı renkli katman (PusuDotView), status butonunun effectiveAppearance'ına göre
//                              açık zeminde #C77700, koyu zeminde #FFC24A
//
// Geometri pusu-menubar-*-template.svg ile birebir aynıdır (18×18 pt, y aşağı doğru).
// Not: Bu dosya Linux ortamında yazıldı, derlenmedi; ilk derlemede küçük düzeltme gerekebilir.

import AppKit
import PusuCore

// MARK: - Durumlar

enum PusuIconState: Equatable {
    case off                          // kapalı: boş kontur, nokta yok
    case awake                        // süresiz uyanık: kontur + nokta
    case timed(remaining: Double)     // süreli: 0…1 kalan oran; geçen kısım %30 alfa
    case lidClosed                    // kapak kapalı modu: gövde dolu
    case vncLock                      // VNC karartma/kilit: tüm glif dolu

    var showsDot: Bool { self != .off }
}

// MARK: - Glif

enum PusuGlyph {
    static let size = NSSize(width: 18, height: 18)
    static let lineWidth: CGFloat = 1.2
    static let headCenter = NSPoint(x: 9, y: 7.0)

    /// Anahtar deliği: baş r=4 (merkez 9,7.003), boyun yarı genişlik 1.4, taban 6.5…11.5
    static func keyhole() -> NSBezierPath {
        let p = NSBezierPath()
        p.lineWidth = lineWidth
        p.lineJoinStyle = .round
        // (7.6,10.75) → üstten büyük yay → (10.4,10.75); flipped düzlemde artan açı = saat yönü
        p.move(to: NSPoint(x: 7.6, y: 10.75))
        p.appendArc(withCenter: NSPoint(x: 9, y: 7.003), radius: 4,
                    startAngle: 110.49, endAngle: 69.51, clockwise: false)
        p.line(to: NSPoint(x: 11.5, y: 14.4))
        p.quad(to: NSPoint(x: 10.8, y: 15.3), control: NSPoint(x: 11.75, y: 15.3))
        p.line(to: NSPoint(x: 7.2, y: 15.3))
        p.quad(to: NSPoint(x: 6.5, y: 14.4), control: NSPoint(x: 6.25, y: 15.3))
        p.close()
        return p
    }

    /// Duruma göre template görsel (yalnızca siyah + alfa)
    static func templateImage(for state: PusuIconState) -> NSImage {
        let img = NSImage(size: size, flipped: true) { _ in
            let path = keyhole()
            let black = NSColor.black
            switch state {
            case .off, .awake:
                black.setStroke(); path.stroke()

            case .timed(let remainingRaw):
                let remaining = max(0, min(1, remainingRaw))
                // 1) tüm kontur %30
                black.withAlphaComponent(0.45).setStroke(); path.stroke()
                // 2) kalan kısım tam alfa: saat 12'den saat yönünde "geçen" dilim hariç + gövde her zaman tam
                NSGraphicsContext.saveGraphicsState()
                let clip = NSBezierPath()
                let elapsed = 1 - remaining
                if remaining > 0 {
                    clip.move(to: headCenter)
                    clip.appendArc(withCenter: headCenter, radius: 6.5,
                                   startAngle: 270 + elapsed * 360, endAngle: 270 + 360,
                                   clockwise: false)
                    clip.close()
                }
                clip.append(NSBezierPath(rect: NSRect(x: 0, y: 10.6, width: 18, height: 8)))
                clip.addClip()
                black.setStroke(); path.stroke()
                NSGraphicsContext.restoreGraphicsState()

            case .lidClosed:
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: NSRect(x: 0, y: 10.4, width: 18, height: 8)).addClip()
                black.setFill(); path.fill()
                NSGraphicsContext.restoreGraphicsState()
                black.setStroke(); path.stroke()

            case .vncLock:
                black.setFill(); path.fill()
                black.setStroke(); path.stroke()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = accessibilityLabel(for: state)
        return img
    }

    static func accessibilityLabel(for state: PusuIconState) -> String {
        switch state {
        case .off: return L("Pusu: kapalı", "Pusu: off")
        case .awake: return L("Pusu: uyanık", "Pusu: awake")
        case .timed: return L("Pusu: süreli uyanık", "Pusu: awake on a timer")
        case .lidClosed: return L("Pusu: kapak kapalı modu", "Pusu: lid mode")
        case .vncLock: return L("Pusu: uzak erişim modu", "Pusu: remote access mode")
        }
    }
}

// MARK: - Amber nokta katmanı

final class PusuDotView: NSView {
    static let amberOnLight = NSColor(srgbRed: 0xC7/255, green: 0x77/255, blue: 0x00/255, alpha: 1) // #C77700
    static let amberOnDark  = NSColor(srgbRed: 0xFF/255, green: 0xC2/255, blue: 0x4A/255, alpha: 1) // #FFC24A

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // tıklamaları butona bırak

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (isDark ? Self.amberOnDark : Self.amberOnLight).setFill()
        // @2x: r 1.5 (6 px), @1x: r 2.0 (4 px) — piksel ızgarasına net oturur
        let scale = window?.backingScaleFactor ?? 2
        let r: CGFloat = scale >= 2 ? 1.5 : 2.0
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
    }
}

// MARK: - Status item bağlayıcı

final class PusuStatusIcon: PusuStatusIconProtocol {
    private weak var button: NSStatusBarButton?
    private let dot = PusuDotView()
    private(set) var state: PusuIconState = .off

    init(button: NSStatusBarButton) {
        self.button = button
        dot.frame = NSRect(x: 0, y: 0, width: 5, height: 5)
        button.addSubview(dot)
        update(.off)
    }

    func update(_ newState: PusuIconState) {
        state = newState
        guard let button else { return }
        button.image = PusuGlyph.templateImage(for: newState)
        button.setAccessibilityLabel(PusuGlyph.accessibilityLabel(for: newState))
        dot.isHidden = !newState.showsDot
        layoutDot()
    }

    func layoutOverlay() {
        layoutDot()
    }

    /// Buton boyutu değiştiğinde (ör. yanına süre metni eklendiğinde) tekrar çağır.
    func layoutDot() {
        guard let button, let cell = button.cell else { return }
        let imageRect = cell.imageRect(forBounds: button.bounds)   // glifin buton içindeki yeri
        // Glif koordinatında baş merkezi (9,7); butonun koordinat yönüne göre çevir
        let gx = imageRect.minX + PusuGlyph.headCenter.x * (imageRect.width / PusuGlyph.size.width)
        let gyFromTop = PusuGlyph.headCenter.y * (imageRect.height / PusuGlyph.size.height)
        let gy = button.isFlipped ? imageRect.minY + gyFromTop : imageRect.maxY - gyFromTop
        dot.frame = NSRect(x: gx - 2.5, y: gy - 2.5, width: 5, height: 5).integral
        dot.needsDisplay = true
    }
}

// MARK: - Yardımcı

private extension NSBezierPath {
    /// Kuadratik eğriyi kübiğe çevirerek ekler (macOS 13 uyumlu)
    func quad(to end: NSPoint, control c: NSPoint) {
        let s = currentPoint
        curve(to: end,
              controlPoint1: NSPoint(x: s.x + 2/3 * (c.x - s.x), y: s.y + 2/3 * (c.y - s.y)),
              controlPoint2: NSPoint(x: end.x + 2/3 * (c.x - end.x), y: end.y + 2/3 * (c.y - end.y)))
    }
}

// MARK: - Kullanım
//
// let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
// let icon = PusuStatusIcon(button: item.button!)
// icon.update(.awake)
// icon.update(.timed(remaining: 0.6))    // her ~30 sn'de bir güncellemek yeterli
// icon.update(.lidClosed)
// icon.update(.off)
//
// Pil eşiğinde kapanma: ayrı ikon durumu yok → bildirim göster + icon.update(.off)
// Animasyon (yanıp sönme/nefes) kullanma.
