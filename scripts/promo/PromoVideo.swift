// Pusu 60 saniyelik tanıtım videosu.
//
//   swiftc -O -o build/promo-render scripts/promo/PromoVideo.swift
//   build/promo-render en docs/promo/pusu-intro-en.mp4 [kare-klasörü]
//
// Her kare AppKit/CoreGraphics ile çizilir ve AVFoundation ile H.264 MP4'e yazılır.
// Kullanılan tüm görseller bu depodan gelir (ikon, ekran görüntüleri); müzik yoktur.
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Ayarlar

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("Kullanım: promo <en|tr> <çıktı.mp4> [kare-klasörü]")
    exit(2)
}
let lang = args[1]
let outputURL = URL(fileURLWithPath: args[2])
let frameDir = args.count > 3 ? URL(fileURLWithPath: args[3]) : nil
let tr = lang == "tr"
func T(_ en: String, _ trText: String) -> String { tr ? trText : en }

let W: CGFloat = 1920
let H: CGFloat = 1080
let fps = 30
let duration: Double = 60
let totalFrames = Int(duration) * fps
let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func loadImage(_ path: String) -> NSImage {
    guard let image = NSImage(contentsOf: repo.appendingPathComponent(path)) else {
        fatalError("Görsel yok: \(path) (depo kökünden çalıştırın)")
    }
    return image
}

let appIcon = loadImage("Resources/Icons/A/pusu-icon-1024.png")
let shotSession = loadImage("docs/screenshots/session-\(lang)-dark.png")
let shotHistory = loadImage("docs/screenshots/history-\(lang)-dark.png")

// MARK: - Renkler ve yardımcılar

let amber = NSColor(srgbRed: 1.0, green: 0.76, blue: 0.29, alpha: 1)
let amberDeep = NSColor(srgbRed: 1.0, green: 0.60, blue: 0.15, alpha: 1)
let white = NSColor.white
let dim = NSColor(white: 1, alpha: 0.62)
let faint = NSColor(white: 1, alpha: 0.35)
let red = NSColor(srgbRed: 1.0, green: 0.36, blue: 0.33, alpha: 1)
let green = NSColor(srgbRed: 0.30, green: 0.85, blue: 0.45, alpha: 1)

func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
/// t'nin [a, b] aralığındaki ilerlemesi (0…1).
func prog(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func lerp(_ a: CGFloat, _ b: CGFloat, _ x: Double) -> CGFloat { a + (b - a) * CGFloat(x) }

/// Sahne görünürlüğü: başta ve sonda yumuşak geçiş.
func sceneAlpha(_ t: Double, _ start: Double, _ end: Double, fade: Double = 0.5) -> CGFloat {
    guard t >= start - 0.001, t <= end + 0.001 else { return 0 }
    let fadeIn = start <= 0 ? 1 : prog(t, start, start + fade)
    let fadeOut = 1 - prog(t, end - fade, end)
    return CGFloat(easeInOut(fadeIn) * easeInOut(fadeOut))
}

var ctx: CGContext!

func withAlpha(_ alpha: CGFloat, _ body: () -> Void) {
    guard alpha > 0.001 else { return }
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    body()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

enum Align { case left, center, right }

@discardableResult
func text(
    _ string: String,
    x: CGFloat,
    y: CGFloat,
    size: CGFloat,
    weight: NSFont.Weight = .regular,
    color: NSColor = white,
    align: Align = .center,
    mono: Bool = false,
    alpha: CGFloat = 1,
    kern: CGFloat = 0
) -> NSSize {
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    let attributed = NSAttributedString(string: string, attributes: [
        .font: font,
        .foregroundColor: color.withAlphaComponent(color.alphaComponent * alpha),
        .kern: kern,
    ])
    let measured = attributed.size()
    var origin = NSPoint(x: x, y: y)
    switch align {
    case .left: break
    case .center: origin.x -= measured.width / 2
    case .right: origin.x -= measured.width
    }
    attributed.draw(at: origin)
    return measured
}

/// Daktilo efekti: metnin ilk n karakteri.
func typed(_ string: String, _ x: Double) -> String {
    let count = Int((Double(string.count) * clamp(x)).rounded(.down))
    return String(string.prefix(count))
}

func fill(_ path: NSBezierPath, _ color: NSColor) { color.setFill(); path.fill() }
func stroke(_ path: NSBezierPath, _ color: NSColor, _ width: CGFloat) {
    color.setStroke(); path.lineWidth = width; path.stroke()
}

func radialGlow(center: CGPoint, radius: CGFloat, color: NSColor, alpha: CGFloat) {
    let colors = [
        color.withAlphaComponent(alpha).cgColor,
        color.withAlphaComponent(alpha * 0.3).cgColor,
        color.withAlphaComponent(0).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

func symbol(_ name: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
}

func drawSymbol(_ name: String, center: CGPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
    guard let image = symbol(name, size: size, color: color, weight: weight) else { return }
    let s = image.size
    image.draw(in: NSRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height),
               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

func drawImage(_ image: NSImage, in rect: NSRect, alpha: CGFloat = 1) {
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
}

extension NSBezierPath {
    /// İkinci derece Bézier (uygulamadaki glif çizimiyle aynı).
    func quad(to end: NSPoint, control: NSPoint) {
        let start = currentPoint
        let c1 = NSPoint(x: start.x + 2.0 / 3.0 * (control.x - start.x), y: start.y + 2.0 / 3.0 * (control.y - start.y))
        let c2 = NSPoint(x: end.x + 2.0 / 3.0 * (control.x - end.x), y: end.y + 2.0 / 3.0 * (control.y - end.y))
        curve(to: end, controlPoint1: c1, controlPoint2: c2)
    }
}

// MARK: - Pusu glifi (uygulamadaki menü çubuğu ikonunun vektör kopyası)

enum GlyphState { case off, awake, timed(Double), lid, vnc }

func keyholePath() -> NSBezierPath {
    let p = NSBezierPath()
    p.lineJoinStyle = .round
    p.move(to: NSPoint(x: 7.6, y: 10.75))
    p.appendArc(withCenter: NSPoint(x: 9, y: 7.003), radius: 4, startAngle: 110.49, endAngle: 69.51, clockwise: false)
    p.line(to: NSPoint(x: 11.5, y: 14.4))
    p.quad(to: NSPoint(x: 10.8, y: 15.3), control: NSPoint(x: 11.75, y: 15.3))
    p.line(to: NSPoint(x: 7.2, y: 15.3))
    p.quad(to: NSPoint(x: 6.5, y: 14.4), control: NSPoint(x: 6.25, y: 15.3))
    p.close()
    return p
}

/// 18×18 birimlik glifi verilen merkez ve ölçekte çizer.
func drawGlyph(_ state: GlyphState, center: CGPoint, scale: CGFloat, color: NSColor = white) {
    ctx.saveGState()
    ctx.translateBy(x: center.x - 9 * scale, y: center.y - 9 * scale)
    ctx.scaleBy(x: scale, y: scale)
    let path = keyholePath()
    let lw: CGFloat = 1.2
    switch state {
    case .off:
        stroke(path, color, lw)
    case .awake:
        stroke(path, color, lw)
        fill(NSBezierPath(ovalIn: NSRect(x: 7.5, y: 5.5, width: 3, height: 3)), amber)
    case .timed(let remaining):
        stroke(path, color.withAlphaComponent(0.4), lw)
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath()
        let elapsed = 1 - clamp(remaining)
        let c = NSPoint(x: 9, y: 7)
        if remaining > 0 {
            clip.move(to: c)
            clip.appendArc(withCenter: c, radius: 6.5, startAngle: 270 + CGFloat(elapsed) * 360, endAngle: 630, clockwise: false)
            clip.close()
        }
        clip.append(NSBezierPath(rect: NSRect(x: 0, y: 10.6, width: 18, height: 8)))
        clip.addClip()
        stroke(path, color, lw)
        NSGraphicsContext.restoreGraphicsState()
        fill(NSBezierPath(ovalIn: NSRect(x: 7.5, y: 5.5, width: 3, height: 3)), amber)
    case .lid:
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: 10.4, width: 18, height: 8)).addClip()
        fill(path, color)
        NSGraphicsContext.restoreGraphicsState()
        stroke(path, color, lw)
        fill(NSBezierPath(ovalIn: NSRect(x: 7.5, y: 5.5, width: 3, height: 3)), amber)
    case .vnc:
        fill(path, color)
        stroke(path, color, lw)
    }
    ctx.restoreGState()
}

func drawCursor(at p: CGPoint, scale: CGFloat = 1.6, pressed: Bool = false) {
    ctx.saveGState()
    ctx.translateBy(x: p.x, y: p.y)
    ctx.scaleBy(x: scale * (pressed ? 0.9 : 1), y: scale * (pressed ? 0.9 : 1))
    let arrow = NSBezierPath()
    arrow.move(to: .zero)
    arrow.line(to: NSPoint(x: 0, y: 22))
    arrow.line(to: NSPoint(x: 5.5, y: 16.5))
    arrow.line(to: NSPoint(x: 9.5, y: 25))
    arrow.line(to: NSPoint(x: 13, y: 23.4))
    arrow.line(to: NSPoint(x: 9, y: 15))
    arrow.line(to: NSPoint(x: 16.5, y: 15))
    arrow.close()
    fill(arrow, .black)
    stroke(arrow, .white, 1.6)
    ctx.restoreGState()
}

// MARK: - Arka plan

var stars: [(CGPoint, CGFloat, CGFloat)] = {
    var generator = SystemRandomNumberGenerator()
    return (0..<170).map { _ in
        (CGPoint(x: .random(in: 0...W, using: &generator), y: .random(in: 0...H, using: &generator)),
         .random(in: 0.8...2.4, using: &generator),
         .random(in: 0.05...0.3, using: &generator))
    }
}()

func drawBackground(_ t: Double) {
    let bg = NSGradient(colors: [
        NSColor(srgbRed: 0.035, green: 0.050, blue: 0.105, alpha: 1),
        NSColor(srgbRed: 0.070, green: 0.090, blue: 0.180, alpha: 1),
        NSColor(srgbRed: 0.035, green: 0.050, blue: 0.110, alpha: 1),
    ])!
    bg.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)
    for (index, star) in stars.enumerated() {
        let twinkle = 0.7 + 0.3 * sin(t * 0.8 + Double(index))
        NSColor(white: 1, alpha: star.2 * CGFloat(twinkle)).setFill()
        let drift = CGFloat(t) * 3
        NSBezierPath(ovalIn: NSRect(x: (star.0.x + drift).truncatingRemainder(dividingBy: W), y: star.0.y, width: star.1, height: star.1)).fill()
    }
    // yavaşça nefes alan amber hale
    let breathe = 0.85 + 0.15 * sin(t * 0.9)
    radialGlow(center: CGPoint(x: W / 2, y: H * 0.42), radius: 900, color: amberDeep, alpha: 0.10 * CGFloat(breathe))
}

func caption(_ title: String, _ subtitle: String?, y: CGFloat, alpha: CGFloat) {
    text(title, x: W / 2, y: y, size: 64, weight: .bold, alpha: alpha)
    if let subtitle {
        text(subtitle, x: W / 2, y: y + 92, size: 34, weight: .regular, color: dim, alpha: alpha)
    }
}

// MARK: - Sahneler

/// 0–6 sn: kanca
func sceneHook(_ t: Double) {
    let a = sceneAlpha(t, 0, 6.2)
    withAlpha(a) {
        let line1 = T("Your Mac went to sleep.", "Mac'in uykuya daldı.")
        let line2 = T("Mid-download. Mid-render. Mid-call.", "İndirme yarıda. Render yarıda. Toplantı yarıda.")
        text(typed(line1, prog(t, 0.4, 2.2)), x: W / 2, y: 420, size: 78, weight: .bold)
        text(line2, x: W / 2, y: 540, size: 40, color: dim, alpha: CGFloat(easeOut(prog(t, 2.6, 3.6))))
        // uyuyan ekran: soluklaşan bir dikdörtgen
        let sleepy = 1 - easeInOut(prog(t, 3.8, 5.6))
        let frame = NSBezierPath(roundedRect: NSRect(x: W / 2 - 90, y: 660, width: 180, height: 112), xRadius: 12, yRadius: 12)
        fill(frame, NSColor(white: 1, alpha: 0.06 + 0.10 * CGFloat(sleepy)))
        stroke(frame, NSColor(white: 1, alpha: 0.25), 2)
        text("z", x: W / 2 + 120, y: 680 - CGFloat(prog(t, 3.8, 6)) * 30, size: 38, weight: .semibold, color: faint, alpha: CGFloat(prog(t, 3.8, 4.4)))
        text("z", x: W / 2 + 152, y: 650 - CGFloat(prog(t, 4.2, 6)) * 30, size: 28, weight: .semibold, color: faint, alpha: CGFloat(prog(t, 4.2, 4.8)))
    }
}

/// 6–12 sn: logo
func sceneLogo(_ t: Double) {
    let a = sceneAlpha(t, 6, 12.2)
    withAlpha(a) {
        let local = t - 6
        let pop = easeOut(prog(local, 0, 1.2))
        let size = lerp(220, 300, pop)
        let center = CGPoint(x: W / 2, y: 380)
        radialGlow(center: center, radius: lerp(120, 460, pop), color: amber, alpha: 0.45 * CGFloat(pop))
        ctx.saveGState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 40
        shadow.shadowOffset = NSSize(width: 0, height: 18)
        shadow.set()
        drawImage(appIcon, in: NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size), alpha: CGFloat(pop))
        ctx.restoreGState()
        let titleIn = easeOut(prog(local, 1.0, 2.0))
        text("Pusu", x: W / 2, y: 580 + (1 - CGFloat(titleIn)) * 30, size: 140, weight: .bold, alpha: CGFloat(titleIn), kern: 2)
        text(T("Keeps your Mac awake.", "Mac'in uyanık kalsın."), x: W / 2, y: 770, size: 50, weight: .semibold, color: amber, alpha: CGFloat(easeOut(prog(local, 2.0, 3.0))))
        text(T("A free menu bar app for macOS", "macOS için ücretsiz bir menü çubuğu uygulaması"), x: W / 2, y: 850, size: 32, color: dim, alpha: CGFloat(easeOut(prog(local, 2.6, 3.6))))
    }
}

/// 12–20 sn: menü çubuğu
func sceneMenuBar(_ t: Double) {
    let a = sceneAlpha(t, 12, 20.2)
    withAlpha(a) {
        let local = t - 12
        // büyütülmüş menü çubuğu şeridi
        let bar = NSRect(x: 260, y: 300, width: W - 520, height: 120)
        let barPath = NSBezierPath(roundedRect: bar, xRadius: 28, yRadius: 28)
        fill(barPath, NSColor(white: 1, alpha: 0.08))
        stroke(barPath, NSColor(white: 1, alpha: 0.14), 2)

        let iconCenter = CGPoint(x: bar.minX + 470, y: bar.midY)
        let clickAt = 1.6
        let totalSeconds: Double = 90 * 60
        let timedStart = 3.2
        let state: GlyphState
        var countdown: String?
        if local < clickAt {
            state = .off
        } else if local < timedStart {
            state = .awake
        } else {
            let elapsed = (local - timedStart) * 380   // hızlandırılmış zaman
            let remaining = max(0, totalSeconds - elapsed)
            state = .timed(remaining / totalSeconds)
            let r = Int(remaining)
            countdown = String(format: "%d:%02d:%02d", r / 3600, (r % 3600) / 60, r % 60)
        }
        drawGlyph(state, center: iconCenter, scale: 4.2)
        if let countdown {
            text(countdown, x: iconCenter.x + 56, y: iconCenter.y - 30, size: 46, weight: .medium, align: .left, mono: true)
        }
        // diğer menü öğeleri
        drawSymbol("battery.75percent", center: CGPoint(x: bar.minX + 930, y: bar.midY), size: 46, color: white)
        text("76%", x: bar.minX + 990, y: bar.midY - 26, size: 40, weight: .medium, align: .left)
        drawSymbol("wifi", center: CGPoint(x: bar.minX + 1130, y: bar.midY), size: 42, color: white)
        text(T("Thu 14:32", "Per 14:32"), x: bar.maxX - 40, y: bar.midY - 26, size: 40, weight: .medium, align: .right)

        // imleç
        let cursorStart = CGPoint(x: iconCenter.x + 330, y: iconCenter.y + 120)
        let move = easeInOut(prog(local, 0.3, 1.4))
        let cursor = CGPoint(x: lerp(cursorStart.x, iconCenter.x + 6, move), y: lerp(cursorStart.y, iconCenter.y + 10, move))
        let pressed = local > clickAt - 0.15 && local < clickAt + 0.15
        if local < 3.0 { drawCursor(at: cursor, pressed: pressed) }
        if local > clickAt, local < clickAt + 0.6 {
            let ring = prog(local, clickAt, clickAt + 0.6)
            let r = lerp(30, 110, ring)
            stroke(NSBezierPath(ovalIn: NSRect(x: iconCenter.x - r, y: iconCenter.y - r, width: r * 2, height: r * 2)), amber.withAlphaComponent(CGFloat(1 - ring)), 4)
        }

        let title = local < timedStart
            ? T("One click in the menu bar.", "Menü çubuğunda tek tık.")
            : T("On a timer, or indefinitely.", "Süreli ya da süresiz.")
        let subtitle = local < timedStart
            ? T("Your Mac stays awake until you say so.", "Sen kapatana kadar Mac uyanık kalır.")
            : T("15 minutes to 8 hours, with a live countdown.", "15 dakikadan 8 saate, canlı geri sayımla.")
        caption(title, subtitle, y: 560, alpha: 1)
    }
}

/// 20–28 sn: Ayarlar ekranları
func sceneScreens(_ t: Double) {
    let a = sceneAlpha(t, 20, 28.2)
    withAlpha(a) {
        let local = t - 20
        let slide = easeOut(prog(local, 0, 1.0))
        // sol: başlık ve maddeler
        text(T("Everything at a glance.", "Her şey tek bakışta."), x: 150, y: 330, size: 66, weight: .bold, align: .left, alpha: CGFloat(slide))
        let bullets = [
            T("Live countdown and battery", "Canlı geri sayım ve pil"),
            T("Lid mode and remote access", "Kapak modu ve uzak erişim"),
            T("Today's timeline and history", "Bugünün zaman çizelgesi ve geçmiş"),
        ]
        for (index, bullet) in bullets.enumerated() {
            let appear = easeOut(prog(local, 0.8 + Double(index) * 0.45, 1.4 + Double(index) * 0.45))
            fill(NSBezierPath(ovalIn: NSRect(x: 154, y: 470 + CGFloat(index) * 78, width: 14, height: 14)), amber.withAlphaComponent(CGFloat(appear)))
            text(bullet, x: 190, y: 448 + CGFloat(index) * 78, size: 38, color: dim, align: .left, alpha: CGFloat(appear))
        }
        // sağ: ekran görüntüsü, ortada geçmişe geçer
        let shotHeight: CGFloat = 900
        let shotWidth = shotHeight * shotSession.size.width / shotSession.size.height
        let x = W - shotWidth - 80 + (1 - CGFloat(slide)) * 120
        let rect = NSRect(x: x, y: (H - shotHeight) / 2 + 20, width: shotWidth, height: shotHeight)
        let swap = easeInOut(prog(local, 4.0, 4.8))
        drawImage(shotSession, in: rect, alpha: CGFloat(slide) * CGFloat(1 - swap))
        drawImage(shotHistory, in: rect, alpha: CGFloat(slide) * CGFloat(swap))
    }
}

/// 28–35 sn: pil koruması
func sceneBattery(_ t: Double) {
    let a = sceneAlpha(t, 28, 35.2)
    withAlpha(a) {
        let local = t - 28
        let drain = easeInOut(prog(local, 0.6, 4.0))
        let percent = Int((34 - 24 * drain).rounded())
        let tripped = percent <= 10
        let body = NSRect(x: W / 2 - 260, y: 250, width: 480, height: 220)
        let bodyPath = NSBezierPath(roundedRect: body, xRadius: 40, yRadius: 40)
        stroke(bodyPath, white, 10)
        fill(NSBezierPath(roundedRect: NSRect(x: body.maxX + 14, y: body.midY - 45, width: 26, height: 90), xRadius: 10, yRadius: 10), white)
        let inner = body.insetBy(dx: 22, dy: 22)
        let level = NSRect(x: inner.minX, y: inner.minY, width: inner.width * CGFloat(percent) / 100, height: inner.height)
        let levelColor = percent <= 15 ? red : amber
        fill(NSBezierPath(roundedRect: level, xRadius: 18, yRadius: 18), levelColor)
        text("\(T("", "%"))\(percent)\(T("%", ""))", x: W / 2 - 20, y: body.midY - 62, size: 104, weight: .bold, color: white)

        // ikon: süreli → kapalı
        let iconCenter = CGPoint(x: W / 2, y: 560)
        drawGlyph(tripped ? .off : .timed(0.55), center: iconCenter, scale: 3.6)
        if tripped {
            text(T("Pusu turned itself off at 10%.", "Pusu %10'da kendini kapattı."), x: W / 2, y: 610, size: 34, color: dim, alpha: CGFloat(easeOut(prog(local, 4.0, 4.6))))
        }
        caption(
            T("Never drains your battery.", "Pilini asla bitirmez."),
            T("It turns itself off at the level you choose.", "Seçtiğin seviyede kendini kapatır."),
            y: 750,
            alpha: 1
        )
    }
}

/// 35–42 sn: kapak modu
func sceneLid(_ t: Double) {
    let a = sceneAlpha(t, 35, 42.2)
    withAlpha(a) {
        let local = t - 35
        let close = easeInOut(prog(local, 1.0, 3.2))
        let baseWidth: CGFloat = 460
        let hinge = CGPoint(x: W / 2 - baseWidth / 2, y: 520)
        // ekran ışığı: kapak açıkken geniş, kapanınca kaybolur
        radialGlow(center: CGPoint(x: W / 2 - 40, y: hinge.y - 140), radius: 360, color: amber, alpha: 0.28 * CGFloat(1 - close))
        // taban
        let base = NSBezierPath(roundedRect: NSRect(x: hinge.x, y: hinge.y, width: baseWidth, height: 22), xRadius: 11, yRadius: 11)
        fill(base, NSColor(white: 0.85, alpha: 1))
        // kapak: menteşe etrafında açıktan kapalıya döner (yan görünüş)
        let angle = lerp(100, 1.5, close) * .pi / 180
        ctx.saveGState()
        ctx.translateBy(x: hinge.x, y: hinge.y)
        ctx.rotate(by: -angle)
        let lid = NSBezierPath(roundedRect: NSRect(x: 0, y: -20, width: baseWidth - 16, height: 20), xRadius: 10, yRadius: 10)
        fill(lid, NSColor(white: 0.74, alpha: 1))
        fill(NSBezierPath(roundedRect: NSRect(x: 24, y: -2, width: baseWidth - 64, height: 10), xRadius: 5, yRadius: 5), amber.withAlphaComponent(0.9))
        ctx.restoreGState()
        // kapak kapandıktan sonra tabanın önünde yanan "çalışıyor" ışığı
        let led = easeOut(prog(local, 3.2, 3.6))
        let pulse = 0.6 + 0.4 * sin(local * 4)
        fill(NSBezierPath(ovalIn: NSRect(x: hinge.x + baseWidth - 40, y: hinge.y + 6, width: 10, height: 10)), green.withAlphaComponent(CGFloat(led * pulse)))

        // kapak kapandıktan sonra: hâlâ çalışıyor göstergeleri
        let after = easeOut(prog(local, 3.4, 4.2))
        let chips = [
            ("arrow.down.circle", T("Download 87%", "İndirme %87")),
            ("hammer", T("Build running", "Derleme sürüyor")),
            ("server.rack", T("Server up", "Sunucu ayakta")),
        ]
        for (index, chip) in chips.enumerated() {
            let appear = easeOut(prog(local, 3.4 + Double(index) * 0.3, 4.0 + Double(index) * 0.3))
            let x = W / 2 - 520 + CGFloat(index) * 360
            let box = NSRect(x: x, y: 300, width: 320, height: 76)
            let chipPath = NSBezierPath(roundedRect: box, xRadius: 38, yRadius: 38)
            withAlpha(CGFloat(appear)) {
                fill(chipPath, NSColor(white: 1, alpha: 0.08))
                stroke(chipPath, green.withAlphaComponent(0.6), 2)
                drawSymbol(chip.0, center: CGPoint(x: box.minX + 44, y: box.midY), size: 30, color: green)
                text(chip.1, x: box.minX + 78, y: box.midY - 20, size: 30, weight: .medium, align: .left)
            }
        }
        _ = after
        if local < 3.2 {
            caption(T("Close the lid…", "Kapağı kapat…"), nil, y: 680, alpha: CGFloat(1 - prog(local, 2.9, 3.2)))
        } else {
            caption(
                T("Lid closed. Still working.", "Kapak kapalı. İş sürüyor."),
                T("Lid mode keeps downloads, builds and servers running.", "Kapak modu indirmeleri, derlemeleri ve sunucuları çalıştırır."),
                y: 680,
                alpha: CGFloat(easeOut(prog(local, 3.2, 3.6)))
            )
        }
    }
}

/// 42–48 sn: uzak erişim
func sceneRemote(_ t: Double) {
    let a = sceneAlpha(t, 42, 48.2)
    withAlpha(a) {
        let local = t - 42
        let dark = easeInOut(prog(local, 0.8, 1.8))
        let monitor = NSRect(x: W / 2 - 300, y: 170, width: 600, height: 370)
        let monitorPath = NSBezierPath(roundedRect: monitor, xRadius: 26, yRadius: 26)
        fill(monitorPath, NSColor(white: 0.16, alpha: 1))
        let screen = monitor.insetBy(dx: 18, dy: 18)
        let screenPath = NSBezierPath(roundedRect: screen, xRadius: 12, yRadius: 12)
        let lit = NSGradient(colors: [NSColor(srgbRed: 0.25, green: 0.35, blue: 0.65, alpha: 1), NSColor(srgbRed: 0.45, green: 0.30, blue: 0.55, alpha: 1)])!
        lit.draw(in: screenPath, angle: -45)
        fill(screenPath, NSColor.black.withAlphaComponent(CGFloat(dark)))
        // stand
        fill(NSBezierPath(rect: NSRect(x: W / 2 - 30, y: monitor.maxY, width: 60, height: 50)), NSColor(white: 0.3, alpha: 1))
        fill(NSBezierPath(roundedRect: NSRect(x: W / 2 - 130, y: monitor.maxY + 46, width: 260, height: 16), xRadius: 8, yRadius: 8), NSColor(white: 0.3, alpha: 1))
        // kilit
        let lockIn = easeOut(prog(local, 1.8, 2.4))
        drawSymbol("lock.fill", center: CGPoint(x: screen.midX, y: screen.midY - 10), size: 90, color: NSColor(white: 1, alpha: 0.85 * CGFloat(lockIn)))
        // VNC bağlantı dalgası
        let pulseStart = 2.8
        if local > pulseStart {
            for i in 0..<3 {
                let p = ((local - pulseStart) * 0.8 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let r = lerp(40, 180, p)
                let c = CGPoint(x: monitor.maxX + 160, y: monitor.midY)
                stroke(NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), amber.withAlphaComponent(CGFloat(1 - p) * 0.8), 4)
            }
            drawSymbol("display", center: CGPoint(x: monitor.maxX + 160, y: monitor.midY), size: 56, color: amber)
            text("VNC", x: monitor.maxX + 160, y: monitor.midY + 52, size: 28, weight: .semibold, color: amber)
        }
        caption(
            T("Ready for remote access.", "Uzaktan bağlanmaya hazır."),
            T("Display off, session locked, system awake for Screen Sharing.", "Ekran kapalı, oturum kilitli, sistem Ekran Paylaşımı için uyanık."),
            y: 690,
            alpha: 1
        )
    }
}

/// 48–54 sn: terminal
func sceneTerminal(_ t: Double) {
    let a = sceneAlpha(t, 48, 54.2)
    withAlpha(a) {
        let local = t - 48
        text(T("Scriptable, too.", "Komut satırından da."), x: W / 2, y: 150, size: 64, weight: .bold)
        let window = NSRect(x: W / 2 - 560, y: 270, width: 1120, height: 560)
        let windowPath = NSBezierPath(roundedRect: window, xRadius: 20, yRadius: 20)
        fill(windowPath, NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 0.96))
        stroke(windowPath, NSColor(white: 1, alpha: 0.12), 2)
        for (i, color) in [NSColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1), NSColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1), NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1)].enumerated() {
            fill(NSBezierPath(ovalIn: NSRect(x: window.minX + 24 + CGFloat(i) * 30, y: window.minY + 22, width: 18, height: 18)), color)
        }
        let lines: [(cmd: String, out: [String], at: Double)] = [
            ("pusu on 90", [], 0.4),
            ("pusu lid on", [], 1.5),
            ("pusu status", ["{", "  \"isOn\" : true,", "  \"lidMode\" : true,", "  \"remaining\" : 5398", "}"], 2.6),
        ]
        var y = window.minY + 80
        let lineHeight: CGFloat = 50
        for line in lines {
            guard local >= line.at else { break }
            let typing = prog(local, line.at, line.at + 0.6)
            let prompt = text("$ ", x: window.minX + 40, y: y, size: 36, weight: .regular, color: green, align: .left, mono: true)
            text(typed(line.cmd, typing), x: window.minX + 40 + prompt.width, y: y, size: 36, weight: .medium, align: .left, mono: true)
            y += lineHeight
            if typing >= 1 {
                for (index, out) in line.out.enumerated() {
                    let show = prog(local, line.at + 0.7 + Double(index) * 0.08, line.at + 0.8 + Double(index) * 0.08)
                    if show > 0 {
                        text(out, x: window.minX + 40, y: y, size: 32, color: dim, align: .left, mono: true, alpha: CGFloat(show))
                        y += 44
                    }
                }
            }
        }
        if Int(local * 2) % 2 == 0 {
            fill(NSBezierPath(rect: NSRect(x: window.minX + 40, y: y + 6, width: 18, height: 36)), NSColor(white: 1, alpha: 0.7))
        }
        text(T("Also: a global shortcut and pusu:// links for Shortcuts.", "Ayrıca: global kısayol ve Kestirmeler için pusu:// bağlantıları."), x: W / 2, y: 880, size: 32, color: dim)
    }
}

/// 54–60 sn: kapanış
func sceneOutro(_ t: Double) {
    let a = sceneAlpha(t, 54, 60.5, fade: 0.6)
    withAlpha(a) {
        let local = t - 54
        let pop = easeOut(prog(local, 0, 1.0))
        let center = CGPoint(x: W / 2, y: 300)
        radialGlow(center: center, radius: 380, color: amber, alpha: 0.4 * CGFloat(pop))
        drawImage(appIcon, in: NSRect(x: center.x - 120, y: center.y - 120, width: 240, height: 240), alpha: CGFloat(pop))
        text("Pusu", x: W / 2, y: 450, size: 110, weight: .bold, alpha: CGFloat(pop), kern: 2)
        let info = easeOut(prog(local, 0.8, 1.6))
        text(T("Free and open source · GPL-3.0", "Ücretsiz ve açık kaynak · GPL-3.0"), x: W / 2, y: 610, size: 38, color: amber, alpha: CGFloat(info))
        text(T("macOS 13+ · Apple silicon & Intel · Türkçe & English", "macOS 13+ · Apple silicon ve Intel · Türkçe & English"), x: W / 2, y: 672, size: 30, color: dim, alpha: CGFloat(info))
        let cta = easeOut(prog(local, 1.6, 2.4))
        let pill = NSRect(x: W / 2 - 360, y: 770, width: 720, height: 92)
        withAlpha(CGFloat(cta)) {
            fill(NSBezierPath(roundedRect: pill, xRadius: 46, yRadius: 46), NSColor(white: 1, alpha: 0.10))
            stroke(NSBezierPath(roundedRect: pill, xRadius: 46, yRadius: 46), amber.withAlphaComponent(0.7), 2)
            text("github.com/bilalkan/pusu", x: W / 2, y: pill.midY - 28, size: 46, weight: .semibold, mono: false)
        }
    }
}

func drawFrame(_ t: Double) {
    drawBackground(t)
    sceneHook(t)
    sceneLogo(t)
    sceneMenuBar(t)
    sceneScreens(t)
    sceneBattery(t)
    sceneLid(t)
    sceneRemote(t)
    sceneTerminal(t)
    sceneOutro(t)
    // ince ilerleme çizgisi
    fill(NSBezierPath(rect: NSRect(x: 0, y: H - 6, width: W * CGFloat(t / duration), height: 6)), amber.withAlphaComponent(0.55))
}

// MARK: - Kodlama

try? FileManager.default.removeItem(at: outputURL)
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
if let frameDir { try FileManager.default.createDirectory(at: frameDir, withIntermediateDirectories: true) }

let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: Int(W),
    AVVideoHeightKey: Int(H),
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 1_600_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoMaxKeyFrameIntervalKey: fps * 2,
    ],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: Int(W),
    kCVPixelBufferHeightKey as String: Int(H),
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

// İsteğe bağlı README önizlemesi: PROMO_GIF=yol, PROMO_GIF_RANGE="12.4-20" (sn)
let gifPath = ProcessInfo.processInfo.environment["PROMO_GIF"]
let gifRange: ClosedRange<Double> = {
    let parts = (ProcessInfo.processInfo.environment["PROMO_GIF_RANGE"] ?? "12.4-20").split(separator: "-").compactMap { Double($0) }
    return parts.count == 2 ? parts[0]...parts[1] : 12.4...20
}()
let gifFPS = 15   // 30 fps'nin tam böleni
let gifSize = (w: 960, h: 540)
var gifFrames: [CGImage] = []

for frame in 0..<totalFrames {
    autoreleasepool {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        guard let buffer else { fatalError("piksel tamponu yok") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(W),
            height: Int(H),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        // Sol üst köşe orijinli (y aşağı) çizim düzlemi
        context.translateBy(x: 0, y: H)
        context.scaleBy(x: 1, y: -1)
        ctx = context
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        drawFrame(Double(frame) / Double(fps))
        NSGraphicsContext.restoreGraphicsState()

        if let frameDir, frame % (fps * 2) == fps, let image = context.makeImage() {
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])?
                .write(to: frameDir.appendingPathComponent(String(format: "frame-%02d.jpg", frame / fps)))
        }
        let seconds = Double(frame) / Double(fps)
        if gifPath != nil, gifRange.contains(seconds), frame % (fps / gifFPS) == 0, let image = context.makeImage(),
           let small = CGContext(data: nil, width: gifSize.w, height: gifSize.h, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            small.interpolationQuality = .high
            small.draw(image, in: CGRect(x: 0, y: 0, width: gifSize.w, height: gifSize.h))
            if let scaled = small.makeImage() { gifFrames.append(scaled) }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
    }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
if let gifPath, !gifFrames.isEmpty,
   let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: gifPath) as CFURL, UTType.gif.identifier as CFString, gifFrames.count, nil) {
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let frameProps = [kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFDelayTime: 1.0 / Double(gifFPS),
        kCGImagePropertyGIFUnclampedDelayTime: 1.0 / Double(gifFPS),
    ]] as CFDictionary
    for image in gifFrames { CGImageDestinationAddImage(destination, image, frameProps) }
    if !CGImageDestinationFinalize(destination) { print("GIF yazılamadı") }
}
if writer.status != .completed {
    print("Hata: \(writer.error?.localizedDescription ?? "bilinmiyor")")
    exit(1)
}
print(outputURL.path)
