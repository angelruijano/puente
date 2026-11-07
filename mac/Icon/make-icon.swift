// Dibuja el ícono de Puente (mismo diseño que en Android) y genera Puente.icns
import AppKit

let out = CommandLine.arguments[1] // carpeta .iconset
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // Cuadrado redondeado estilo macOS (824 px dentro de 1024, con sombra suave)
    let box = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: box, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = .black.withAlphaComponent(0.35); sh.shadowBlurRadius = 18 * s
    sh.shadowOffset = NSSize(width: 0, height: -8 * s); sh.set()
    NSGradient(starting: NSColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 1),
               ending: NSColor(red: 0.05, green: 0.055, blue: 0.07, alpha: 1))!.draw(in: shape, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    // Arco y tablero del puente (viewport Android 108 → caja de 824)
    let k = 824 * s / 108, ox = 100 * s, oy = 100 * s
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * k, y: oy + (108 - y) * k) }
    NSColor.white.setStroke()
    // Arco (cuadrática M24,70 Q54,2 84,70 en cúbica), tirantes y tablero
    let arch = NSBezierPath(); arch.move(to: p(24, 70)); arch.curve(to: p(84, 70), controlPoint1: p(44, 24.67), controlPoint2: p(64, 24.67))
    arch.lineWidth = 5 * k; arch.lineCapStyle = .round; arch.stroke()
    for (x, y) in [(39.0, 44.5), (54.0, 36.0), (69.0, 44.5)] {
        let h = NSBezierPath(); h.move(to: p(CGFloat(x), CGFloat(y))); h.line(to: p(CGFloat(x), 70))
        h.lineWidth = 3 * k; h.stroke()
    }
    let deck = NSBezierPath(); deck.move(to: p(16, 70)); deck.line(to: p(92, 70))
    deck.lineWidth = 5 * k; deck.lineCapStyle = .round; deck.stroke()
    // Punto rojo: el otro extremo del puente
    NSColor(red: 0.843, green: 0.098, blue: 0.129, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(origin: p(87, 87), size: NSSize(width: 10 * k, height: 10 * k))).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
