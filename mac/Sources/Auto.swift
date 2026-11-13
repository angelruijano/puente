import AppKit
import CoreAudio
import Network

/// Hotspot automático: si el Mac se queda sin red un rato y el celular está cerca, enciende el hotspot y se une.
/// No insiste: si apagas el hotspot a mano, espera a que el Mac encuentre otra red antes de volver a intentarlo.
final class AutoHotspot {
    /// Se puede intentar ahora (función activada, celular cerca, tapa abierta, pantalla desbloqueada, hotspot libre).
    var canConnect: () -> Bool = { false }
    var connect: () -> Void = {}
    /// Se perdió la red estando en el hotspot (el celular lo apagó o se alejó).
    var onLost: () -> Void = {}

    static let offlineDelay: TimeInterval = 20   // sin red este tiempo → hotspot
    static let retryDelay: TimeInterval = 180    // tras un intento, esperar antes de otro

    private let monitor = NWPathMonitor()
    private(set) var online = true
    private var offlineSince: Date?
    private var lastTry = Date.distantPast
    private var suppressed = false
    private var sawOfflineWhileSuppressed = false
    private var timer: Timer?

    func start() {
        monitor.pathUpdateHandler = { [weak self] p in
            let ok = p.status == .satisfied
            DispatchQueue.main.async { self?.update(ok) }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        // Al despertar, el Wi‑Fi tarda en volver: contar desde cero
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if !self.online { self.offlineSince = Date() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Apagaste el hotspot a mano: no volver a encenderlo hasta que el Mac esté en otra red.
    func userTurnedOff() { suppressed = true; sawOfflineWhileSuppressed = false }

    private func update(_ ok: Bool) {
        guard ok != online else { return }
        online = ok
        if ok {
            offlineSince = nil
            if suppressed && sawOfflineWhileSuppressed { suppressed = false }
        } else {
            offlineSince = Date()
            if suppressed { sawOfflineWhileSuppressed = true }
            onLost()
        }
    }

    private func tick() {
        guard !online, !suppressed, let since = offlineSince,
              Date().timeIntervalSince(since) >= Self.offlineDelay,
              Date().timeIntervalSince(lastTry) >= Self.retryDelay,
              Self.wifiPowered, canConnect() else { return }
        lastTry = Date()
        Log.info("hotspot automático: el Mac lleva \(Int(Date().timeIntervalSince(since))) s sin red")
        connect()
    }

    /// Con el Wi‑Fi del Mac apagado a propósito no tiene sentido (ni se podría) unirse al hotspot.
    private static var wifiPowered: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-getairportpower", "en0"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return true }
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).hasSuffix("On\n")
    }

    /// Pantalla bloqueada (por ti o por el bloqueo por proximidad): no hay nadie usando el Mac.
    static var screenLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return d["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

/// Micrófono del Mac en uso por una app de reuniones (Meet, Zoom, Teams, FaceTime…).
/// Mira qué app lo tiene abierto: algunas (Discord) lo dejan abierto aunque estés silenciado, y se pueden ignorar.
final class MicWatch {
    var onChange: ((Bool) -> Void)?
    /// La app que tiene el micrófono (nombre visible), o nil.
    var onApp: ((String?) -> Void)?
    private(set) var inUse = false
    private(set) var current: (id: String, name: String)?
    private var since = Date()
    private var raw = false
    private var timer: Timer?

    static let onDelay: TimeInterval = 45    // micrófono abierto este tiempo → reunión (un dictado dura menos)
    static let offDelay: TimeInterval = 15   // y cerrado este tiempo → terminó

    /// Apps ignoradas: identificador → nombre. Discord viene ignorado de entrada.
    var ignored: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "micIgnore") as? [String: String] ?? ["com.hnc.Discord": "Discord"] }
        set { UserDefaults.standard.set(newValue, forKey: "micIgnore"); poll() }
    }

    /// Procesos del sistema que escuchan sin que sea una reunión (dictado, Siri, "Oye Siri", grabar la pantalla).
    private static let system = ["com.apple.CoreSpeech", "com.apple.corespeech", "com.apple.SpeechRecognitionCore",
                                 "com.apple.assistant", "com.apple.siri", "com.apple.Siri", "com.apple.dictation",
                                 "com.apple.voicetrigger", "com.apple.accessibility", "cl.hazlo.puente",
                                 "com.apple.replayd", "com.apple.screencapture", "com.apple.ScreenContinuity"] // grabar la pantalla no es una reunión

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
    }

    func ignoreCurrent() {
        guard let c = current else { return }
        var m = ignored; m[c.id] = c.name; ignored = m
        Log.info("micrófono: se ignora \(c.name)")
    }

    private func poll() {
        let ign = Array(ignored.keys)
        let apps = Self.appsUsingMic().filter { a in !ign.contains { a.id.hasPrefix($0) } }
        let first = apps.first
        if first?.id != current?.id { current = first; onApp?(first?.name) }
        let now = first != nil
        if now != raw { raw = now; since = Date() }
        let wait = raw ? Self.onDelay : Self.offDelay
        guard raw != inUse, Date().timeIntervalSince(since) >= wait else { return }
        inUse = raw
        Log.info("micrófono del Mac: \(inUse ? "en uso (\(first?.name ?? "?"))" : "libre")")
        onChange?(inUse)
    }

    /// Apps que están grabando del micrófono ahora (macOS 14+), agrupadas por app (los ayudantes cuentan como su app).
    static func appsUsingMic() -> [(id: String, name: String)] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let running = NSWorkspace.shared.runningApplications
        var out: [(id: String, name: String)] = []
        for id in ids where uint(id, kAudioProcessPropertyIsRunningInput) != 0 {
            let bundle = string(id, kAudioProcessPropertyBundleID) ?? ""
            if bundle.isEmpty || system.contains(where: { bundle.hasPrefix($0) }) { continue }
            // "com.hnc.Discord.helper.Renderer" → la app "com.hnc.Discord"
            let app = running.filter { a in a.bundleIdentifier.map { bundle == $0 || bundle.hasPrefix($0 + ".") } ?? false }
                .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
            let appID = app?.bundleIdentifier ?? bundle
            if out.contains(where: { $0.id == appID }) { continue }
            out.append((appID, app?.localizedName ?? appID))
        }
        return out
    }

    private static func uint(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v : 0
    }

    private static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr, let s = v?.takeRetainedValue() else { return nil }
        return s as String
    }
}
