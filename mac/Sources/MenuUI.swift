import AppKit
import SwiftUI

/// Estado que muestra el menú. Lo actualiza el AppDelegate.
final class MenuModel: ObservableObject {
    @Published var connected = false
    @Published var wifi = false
    @Published var viaHotspot = false
    @Published var phoneName = UserDefaults.standard.string(forKey: "phoneName") ?? "Tu celular"
    @Published var battery: (level: Int, charging: Bool)? = nil
    @Published var activity: ClipActivity? = nil
    @Published var clipboardOn = true
    @Published var loginOn = false
    @Published var notifOn = true
    @Published var codesOn = true
    @Published var lockOn = true
    @Published var sensitivity = Proximity.Sensitivity.medium
    @Published var proximity = Proximity.Status()
    @Published var hotspot = Hotspot.State.idle
    @Published var hotspotReady = false
    @Published var now = Date()
    @Published var ringing = false
    @Published var mirroring = false
    @Published var photosOn = true
    @Published var dndOn = true
    @Published var dndReady = false
    @Published var autoHotspotOn = true
    @Published var micDndOn = true
    @Published var micApp: String? = nil
    @Published var micIgnored: [String] = []
    @Published var tabError: String? = nil
    @Published var transfer: String?

    var onClipboardToggle: ((Bool) -> Void)?
    var onLoginToggle: ((Bool) -> Void)?
    var onNotifToggle: ((Bool) -> Void)?
    var onCodesToggle: ((Bool) -> Void)?
    var onLockToggle: ((Bool) -> Void)?
    var onSensitivity: ((Proximity.Sensitivity) -> Void)?
    var onHotspot: ((Bool) -> Void)?
    var onMirror: (() -> Void)?
    var onRing: (() -> Void)?
    var onSendTab: (() -> Void)?
    var onCompose: (() -> Void)?
    var onSendFile: (() -> Void)?
    var onPhotosToggle: ((Bool) -> Void)?
    var onDndToggle: ((Bool) -> Void)?
    var onInstallShortcuts: (() -> Void)?
    var onAutoHotspotToggle: ((Bool) -> Void)?
    var onMicDndToggle: ((Bool) -> Void)?
    var onMicIgnoreCurrent: (() -> Void)?
    var onMicIgnoreClear: (() -> Void)?
}

// MARK: - Acciones rápidas

struct ActionsSection: View {
    @ObservedObject var m: MenuModel

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ActionButton(icon: "iphone.gen3", title: m.mirroring ? "Abierta" : "Pantalla",
                             active: m.mirroring, enabled: m.connected && !m.viaHotspot) { m.onMirror?() }
                ActionButton(icon: m.ringing ? "speaker.wave.3.fill" : "dot.radiowaves.left.and.right",
                             title: m.ringing ? "Detener" : "Buscar", active: m.ringing, enabled: m.connected) { m.onRing?() }
                ActionButton(icon: "arrow.up.forward.app", title: "Pestaña",
                             active: false, enabled: m.connected) { m.onSendTab?() }
                ActionButton(icon: "message", title: "Mensajes",
                             active: false, enabled: m.connected) { m.onCompose?() }
                ActionButton(icon: m.transfer == nil ? "square.and.arrow.up" : "arrow.up.arrow.down",
                             title: "Archivo", active: m.transfer != nil, enabled: m.connected) { m.onSendFile?() }
            }
            if let t = m.transfer {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(t).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
            } else if m.connected {
                Text("También puedes soltar archivos en el ícono de Puente").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if let e = m.tabError {
                Text(e).font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(width: 300)
    }
}

struct ActionButton: View {
    let icon: String
    let title: String
    let active: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(active ? Color.accentColor : Color.primary.opacity(0.08)).frame(width: 36, height: 36)
                    Image(systemName: icon).font(.system(size: 15, weight: .medium))
                        .foregroundStyle(active ? .white : .primary)
                }
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

// MARK: - Tarjeta del celular

struct DeviceCard: View {
    @ObservedObject var m: MenuModel

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(m.connected ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 38, height: 38)
                Image(systemName: "smartphone")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(m.connected ? .white : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(m.phoneName).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
                HStack(spacing: 4) {
                    if m.connected {
                        Image(systemName: m.viaHotspot ? "personalhotspot" : m.wifi ? "wifi" : "cable.connector")
                            .font(.system(size: 9, weight: .semibold))
                        Text(m.viaHotspot ? "Conectado por el hotspot" : m.wifi ? "Conectado por Wi‑Fi" : "Conectado por cable")
                        if m.wifi { Image(systemName: "lock.fill").font(.system(size: 8)) }
                    } else {
                        ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
                        Text("Buscando tu celular…")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            }
            Spacer(minLength: 4)
            if let b = m.battery, m.connected { BatteryBadge(level: b.level, charging: b.charging) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 300)
    }
}

struct BatteryBadge: View {
    let level: Int
    let charging: Bool

    private var color: Color {
        if charging { return .green }
        return level <= 20 ? .red : .primary
    }

    var body: some View {
        HStack(spacing: 5) {
            Text("\(level)\u{00A0}%").font(.system(size: 12, weight: .medium).monospacedDigit()).fixedSize()
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5).stroke(Color.secondary.opacity(0.6), lineWidth: 1)
                    .frame(width: 24, height: 12)
                RoundedRectangle(cornerRadius: 2).fill(color)
                    .frame(width: max(2, 20 * CGFloat(level) / 100), height: 8)
                    .padding(.leading, 2)
                if charging {
                    Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white).shadow(radius: 0.5)
                        .frame(width: 24, height: 12)
                }
            }
            .overlay(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.6))
                    .frame(width: 2, height: 5).offset(x: 3)
            }
        }
    }
}

// MARK: - Portapapeles

struct ClipboardSection: View {
    @ObservedObject var m: MenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard").foregroundStyle(Color.accentColor)
                    .font(.system(size: 14)).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Portapapeles compartido").font(.system(size: 13))
                    Text("Copia en uno, pega en el otro").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { m.clipboardOn }, set: { m.clipboardOn = $0; m.onClipboardToggle?($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }

            if let a = m.activity, m.clipboardOn { LastCopy(a: a, now: m.now) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(width: 300, alignment: .leading)
    }
}

struct LastCopy: View {
    let a: ClipActivity
    let now: Date

    private var when: String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es")
        f.unitsStyle = .short
        return now.timeIntervalSince(a.date) < 10 ? "ahora" : f.localizedString(for: a.date, relativeTo: now)
    }

    var body: some View {
        HStack(spacing: 10) {
            preview
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 3) {
                    Image(systemName: a.toPhone ? "arrow.up.right" : "arrow.down.left")
                    Text((a.toPhone ? "Enviado al celular" : "Desde el celular") + " · " + when)
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .onDrag { a.file.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
    }

    @ViewBuilder private var preview: some View {
        switch a.kind {
        case .image(let img?):
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        case .image(nil):
            Image(systemName: "photo").foregroundStyle(.secondary)
        case .text:
            Image(systemName: "text.alignleft").foregroundStyle(.secondary)
        case .sensitive:
            Image(systemName: "key.fill").foregroundStyle(.secondary)
        case .code:
            Image(systemName: "number").foregroundStyle(Color.accentColor)
        }
    }

    private var snippet: String {
        switch a.kind {
        case .text(let s):
            let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return one.isEmpty ? "Texto" : one
        case .image: return a.file?.lastPathComponent ?? "Imagen"
        case .sensitive: return "Contenido sensible ••••••"
        case .code(let c): return "Código " + OTP.pretty(c)
        }
    }
}

// MARK: - Notificaciones

struct NotificationsSection: View {
    @ObservedObject var m: MenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToggleRow(icon: "bell.badge", title: "Notificaciones del celular",
                      subtitle: "Bancos, compras, llamadas y más",
                      isOn: Binding(get: { m.notifOn }, set: { m.notifOn = $0; m.onNotifToggle?($0) }))
            ToggleRow(icon: "number.square", title: "Copiar códigos",
                      subtitle: "Los códigos de SMS quedan listos para ⌘V",
                      isOn: Binding(get: { m.codesOn }, set: { m.codesOn = $0; m.onCodesToggle?($0) }))
            ToggleRow(icon: "photo.on.rectangle", title: "Fotos y capturas",
                      subtitle: "Aparecen solas en el Mac, listas para pegar",
                      isOn: Binding(get: { m.photosOn }, set: { m.photosOn = $0; m.onPhotosToggle?($0) }))
            ToggleRow(icon: "moon.fill", title: "No molestar en ambos",
                      subtitle: m.dndReady ? "Se activa en los dos a la vez" : "Falta añadir 2 atajos",
                      isOn: Binding(get: { m.dndOn }, set: { m.dndOn = $0; m.onDndToggle?($0) }))
            if m.dndOn && !m.dndReady {
                Button("Añadir atajos…") { m.onInstallShortcuts?() }.controlSize(.small).padding(.leading, 30)
            }
            ToggleRow(icon: "mic.fill", title: "Silencio en reuniones",
                      subtitle: "No molestar en el celular si usas el micrófono",
                      isOn: Binding(get: { m.micDndOn }, set: { m.micDndOn = $0; m.onMicDndToggle?($0) }))
            if m.micDndOn {
                if let app = m.micApp {
                    HStack(spacing: 6) {
                        Text("Micrófono: \(app)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        Button("Ignorar") { m.onMicIgnoreCurrent?() }.controlSize(.mini)
                    }.padding(.leading, 30)
                }
                if !m.micIgnored.isEmpty {
                    HStack(spacing: 6) {
                        Text("Se ignora: \(m.micIgnored.joined(separator: ", "))").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        Button("Quitar") { m.onMicIgnoreClear?() }.controlSize(.mini)
                    }.padding(.leading, 30)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(width: 300, alignment: .leading)
    }
}

struct ToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let isOn: Binding<Bool>

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.accentColor)
                .font(.system(size: 14)).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
    }
}

// MARK: - Cerca del Mac: bloqueo y hotspot

struct NearbySection: View {
    @ObservedObject var m: MenuModel

    private var proximityText: String {
        let p = m.proximity
        if !p.bluetoothOn { return "El Bluetooth del Mac está apagado" }
        if !p.seen { return "Sin señal Bluetooth del celular" }
        return p.near ? "Tu celular está cerca" : "Tu celular está lejos"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToggleRow(icon: "lock.shield", title: "Bloquear al alejarme", subtitle: proximityText,
                      isOn: Binding(get: { m.lockOn }, set: { m.lockOn = $0; m.onLockToggle?($0) }))
            if m.lockOn {
                Picker("", selection: Binding(get: { m.sensitivity }, set: { m.sensitivity = $0; m.onSensitivity?($0) })) {
                    ForEach(Proximity.Sensitivity.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .padding(.leading, 30)
            }
            HotspotRow(m: m)
            ToggleRow(icon: "wifi.exclamationmark", title: "Hotspot automático",
                      subtitle: m.hotspotReady ? "Si el Mac se queda sin Wi‑Fi" : "Se activa tras la primera conexión",
                      isOn: Binding(get: { m.autoHotspotOn }, set: { m.autoHotspotOn = $0; m.onAutoHotspotToggle?($0) }))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(width: 300, alignment: .leading)
    }
}

struct HotspotRow: View {
    @ObservedObject var m: MenuModel

    private var subtitle: String {
        switch m.hotspot {
        case .idle: return m.hotspotReady ? (m.proximity.seen ? "Listo para conectar" : "Acerca tu celular") : "Se activa tras la primera conexión"
        case .connecting: return "Encendiendo y conectando…"
        case .connected: return "Conectado a internet del celular"
        case .failed(let why): return why
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "personalhotspot").foregroundStyle(Color.accentColor)
                .font(.system(size: 14)).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("Hotspot del celular").font(.system(size: 13))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            Spacer(minLength: 8)
            switch m.hotspot {
            case .connecting:
                ProgressView().controlSize(.small)
            case .connected:
                Button("Desconectar") { m.onHotspot?(false) }.controlSize(.small)
            default:
                Button("Conectar") { m.onHotspot?(true) }.controlSize(.small)
                    .disabled(!m.hotspotReady || !m.proximity.seen)
            }
        }
    }
}

// MARK: - Ajustes

struct SettingsSection: View {
    @ObservedObject var m: MenuModel

    var body: some View {
        HStack {
            Text("Abrir al iniciar sesión").font(.system(size: 13))
            Spacer()
            Toggle("", isOn: Binding(get: { m.loginOn }, set: { m.loginOn = $0; m.onLoginToggle?($0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .frame(width: 300, alignment: .leading)
    }
}

/// Encabezado de sección gris, como en el Centro de Control.
struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.top, 4)
            .frame(width: 300, alignment: .leading)
    }
}

func hostedItem<V: View>(_ v: V) -> NSMenuItem {
    let item = NSMenuItem()
    let host = NSHostingView(rootView: v)
    host.frame.size = host.fittingSize
    item.view = host
    return item
}

// MARK: - Ícono de la barra: un celular que se llena según la batería

enum StatusIcon {
    static func make(level: Int?, charging: Bool, connected: Bool) -> NSImage {
        let size = NSSize(width: 12, height: 17)
        let img = NSImage(size: size, flipped: false) { r in
            let body = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 2.6, yRadius: 2.6)
            NSColor.black.withAlphaComponent(connected ? 1 : 0.45).setStroke()
            body.lineWidth = 1.4
            body.stroke()

            guard connected else {
                // Diagonal: sin conexión
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 2.5, y: 2.5)); slash.line(to: NSPoint(x: r.maxX - 2.5, y: r.maxY - 2.5))
                slash.lineWidth = 1.3
                NSColor.black.withAlphaComponent(0.45).setStroke()
                slash.stroke()
                return true
            }
            let inner = r.insetBy(dx: 2.6, dy: 2.6)
            let pct = CGFloat(max(0, min(100, level ?? 0))) / 100
            let fill = NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: max(1, inner.height * pct))
            NSColor.black.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 1, yRadius: 1).fill()

            if charging {
                // Rayo recortado (transparente) sobre el relleno
                let bolt = NSBezierPath()
                let cx = r.midX, cy = r.midY
                bolt.move(to: NSPoint(x: cx + 1.2, y: cy + 4.2))
                bolt.line(to: NSPoint(x: cx - 2.2, y: cy - 0.4))
                bolt.line(to: NSPoint(x: cx - 0.1, y: cy - 0.4))
                bolt.line(to: NSPoint(x: cx - 1.2, y: cy - 4.2))
                bolt.line(to: NSPoint(x: cx + 2.2, y: cy + 0.6))
                bolt.line(to: NSPoint(x: cx + 0.1, y: cy + 0.6))
                bolt.close()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                bolt.fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.setStroke()
                bolt.lineWidth = 0.6
                if pct < 0.55 { bolt.stroke() } // visible aunque el relleno sea bajo
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = connected ? "Puente: batería \(level ?? 0)%" : "Puente: sin conexión"
        return img
    }
}
