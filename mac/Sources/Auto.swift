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

/// Micrófono del Mac en uso (Meet, Zoom, Teams, FaceTime…). Avisa con un poco de margen para no saltar con dictados cortos.
final class MicWatch {
    var onChange: ((Bool) -> Void)?
    private(set) var inUse = false
    private var since = Date()
    private var raw = false
    private var timer: Timer?

    static let onDelay: TimeInterval = 6     // micrófono abierto este tiempo → reunión
    static let offDelay: TimeInterval = 15   // y cerrado este tiempo → terminó

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        let now = Self.anyInputRunning()
        if now != raw { raw = now; since = Date() }
        let wait = raw ? Self.onDelay : Self.offDelay
        guard raw != inUse, Date().timeIntervalSince(since) >= wait else { return }
        inUse = raw
        Log.info("micrófono del Mac: \(inUse ? "en uso" : "libre")")
        onChange?(inUse)
    }

    /// Algún micrófono real está grabando. Se ignoran los virtuales (Teams, Zoom, BlackHole…), que pueden quedar abiertos sin llamada.
    static func anyInputRunning() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return false }
        for id in ids where hasInput(id) {
            if uint(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeVirtual { continue }
            if uint(id, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0 { return true }
        }
        return false
    }

    private static func hasInput(_ id: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func uint(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v : 0
    }
}
