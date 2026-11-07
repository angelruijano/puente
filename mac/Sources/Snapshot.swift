import AppKit
import SwiftUI

/// `Puente --snapshot <carpeta>`: dibuja el menú y el ícono en PNG para revisar el diseño.
@MainActor enum Snapshot {
    static func run(_ dir: String) {
        let m = MenuModel()
        m.connected = true; m.wifi = true; m.battery = (72, true); m.loginOn = true
        m.activity = ClipActivity(toPhone: false, kind: .text("https://maps.app.goo.gl/restaurante-favorito"),
                                  date: Date().addingTimeInterval(-90))
        for (name, dark) in [("light", false), ("dark", true)] {
            let v = VStack(spacing: 0) {
                DeviceCard(m: m); Divider().padding(.horizontal, 14)
                ClipboardSection(m: m); Divider().padding(.horizontal, 14)
                SettingsSection(m: m)
            }
            .padding(.vertical, 6)
            .background(dark ? Color(white: 0.17) : Color(white: 0.96))
            .environment(\.colorScheme, dark ? .dark : .light)
            save(v, "\(dir)/menu-\(name).png")
        }
        for (n, lvl, ch, con) in [("72c", 72, true, true), ("35", 35, false, true), ("off", 0, false, false)] {
            let img = StatusIcon.make(level: lvl, charging: ch, connected: con)
            let big = NSImage(size: NSSize(width: 48, height: 68), flipped: false) { r in img.draw(in: r); return true }
            if let t = big.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/icon-\(n).png"))
            }
        }
    }

    private static func save<V: View>(_ v: V, _ path: String) {
        let r = ImageRenderer(content: v)
        r.scale = 2
        if let cg = r.cgImage {
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
