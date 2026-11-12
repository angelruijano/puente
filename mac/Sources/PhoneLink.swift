import AppKit
import Foundation
import Network

/// Mantiene viva la conexión con el celular: busca el dispositivo, lanza el ayudante y reconecta si se cae.
final class PhoneLink {
    enum State: Equatable {
        case searching
        case connected(wifi: Bool)
    }

    static let package = "cl.hazlo.puente"
    static let phoneClipDir = "/sdcard/Android/data/cl.hazlo.puente/files/clip"

    var onState: ((State) -> Void)?
    var onMessage: (([String: Any]) -> Void)?

    private let queue = DispatchQueue(label: "puente.link")
    private var process: Process?
    private var stdin: FileHandle?
    private(set) var device: Adb.Device?
    /// Enlace cifrado propio (sin adb): por el hotspot del celular o por el Wi‑Fi de casa
    enum NetKind { case hotspot, home }
    private var net: NetChannel?
    private(set) var viaNet = false
    private(set) var netKind: NetKind?
    private(set) var netHost: String?
    /// Pide al celular por Bluetooth que encienda la depuración inalámbrica (tras reiniciarse no hay residente)
    var askAdbOverBluetooth: (() -> Bool)?
    private var lastBluetoothAsk = Date.distantPast
    private static let phoneIPKey = "phoneWifiIP"
    var isConnected: Bool { device != nil || viaNet }
    private var buffer = Data()
    private var stopped = false
    /// En pausa (tapa cerrada): sin conexión con el celular hasta que se reanude.
    var paused = false {
        didSet { if paused && !oldValue { process?.terminate(); net?.close() } }
    }

    func start() {
        // Reintentar al tiro cuando cambia la red (llegar a casa, despertar el Mac), sin esperar el turno
        pathMonitor.pathUpdateHandler = { [weak self] p in if p.status == .satisfied { self?.kick("cambió la red") } }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.kick("el Mac despertó")
        }
        queue.async { self.loop() }
    }

    private let pathMonitor = NWPathMonitor()
    private let wake = DispatchSemaphore(value: 0)

    /// Hay motivo para intentar ya (red nueva, Mac despierto, celular a la vista). También permite pedir por Bluetooth de nuevo.
    func kick(_ why: String) {
        guard !isConnected, !paused else { return }
        Log.info("reintentando: \(why)")
        lastBluetoothAsk = .distantPast
        wake.signal()
    }

    func stop() {
        stopped = true
        process?.terminate()
        net?.close()
    }

    // MARK: - Ciclo de conexión

    private func loop() {
        while !stopped {
            if paused { Thread.sleep(forTimeInterval: 1); continue }
            if let (ch, host, kind) = connectNet() {
                runNet(ch, host: host, kind: kind) // lo normal: sin adb
            } else if let dev = findDevice() {
                runHelper(on: dev) // cable, o depuración inalámbrica pedida (p. ej. tras reiniciar el celular)
            } else {
                DispatchQueue.main.async { self.onState?(.searching) }
                askForAdbIfUseful()
            }
            _ = wake.wait(timeout: .now() + 4)
            while wake.wait(timeout: .now()) == .success {} // varios avisos juntos cuentan como uno
        }
    }

    /// Hotspot: el celular es el router. En casa: la IP que informó el celular la última vez.
    private func connectNet(probe: Bool = false) -> (NetChannel, String, NetKind)? {
        let gw = NetChannel.gateway()
        let purpose = probe ? "probe" : "puente"
        if let gw, let ch = NetChannel.connect(host: gw, purpose: purpose, timeout: 1.5) { return (ch, gw, .hotspot) }
        let saved = UserDefaults.standard.string(forKey: Self.phoneIPKey)
        if let ip = saved, ip != gw, let ch = NetChannel.connect(host: ip, purpose: purpose, timeout: 1.5) { return (ch, ip, .home) }
        guard gw != nil else { return nil }
        // El router le dio otra IP: el celular se anuncia en la red de casa (_puente._tcp)
        for addr in Bonjour.find("_puente._tcp.", timeout: 1.5) {
            let ip = String(addr.split(separator: ":")[0])
            guard ip != gw, ip != saved, let ch = NetChannel.connect(host: ip, purpose: purpose, timeout: 1.5) else { continue }
            Log.info("celular encontrado en la red: \(ip)")
            UserDefaults.standard.set(ip, forKey: Self.phoneIPKey)
            return (ch, ip, .home)
        }
        return nil
    }

    /// Sin enlace propio ni adb: si el Mac está en un Wi‑Fi, pedir por Bluetooth la depuración inalámbrica
    /// (el celular solo la enciende en casa). Así se relanza el residente tras un reinicio.
    private func askForAdbIfUseful() {
        guard Date().timeIntervalSince(lastBluetoothAsk) > 90, NetChannel.gateway() != nil else { return }
        let sent = DispatchQueue.main.sync { self.askAdbOverBluetooth?() ?? false }
        if sent { lastBluetoothAsk = Date() }
    }

    private func findDevice() -> Adb.Device? {
        var devs = Adb.devices().filter { !$0.isLegacyTCP }
        if !devs.contains(where: \.isWifi) {
            Adb.connectWireless()
            devs = Adb.devices().filter { !$0.isLegacyTCP }
        }
        return devs.first(where: { !$0.isWifi }) ?? devs.first
    }

    /// adb por Wi‑Fi para algo puntual (ver la pantalla): la pide por el enlace y espera a que aparezca.
    func withAdb(_ done: @escaping (String?) -> Void) {
        if let dev = device { done(dev.serial); return }
        guard netKind == .home else { done(nil); return }
        send(["t": "adbWifi", "on": true])
        DispatchQueue.global().async {
            for _ in 0..<12 {
                Thread.sleep(forTimeInterval: 1.5)
                Adb.connectWireless()
                if let d = Adb.devices().first(where: { $0.isWifi && !$0.isLegacyTCP }) {
                    DispatchQueue.main.async { done(d.serial) }; return
                }
            }
            DispatchQueue.main.async { done(nil) }
        }
    }

    /// Mantener (o soltar) la depuración inalámbrica mientras se usa; el celular la apaga sola a los 5 min.
    func keepAdb(_ on: Bool) { send(["t": "adbWifi", "on": on]) }

    private func runHelper(on dev: Adb.Device) {
        guard !paused else { return }
        let apk = Adb.shell(dev.serial, "pm path \(Self.package)")
            .split(separator: "\n").first?
            .replacingOccurrences(of: "package:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard apk.hasPrefix("/") else { return }
        // Llave del enlace por hotspot: queda en el celular (solo legible por shell) para cuando no haya adb
        _ = Adb.shell(dev.serial, "mkdir -p /data/local/tmp/puente && chmod 700 /data/local/tmp/puente && umask 077 && printf %s \(NetChannel.key.hex) > /data/local/tmp/puente/net.key", timeout: 5)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Adb.path)
        p.arguments = ["-s", dev.serial, "shell",
                       "CLASSPATH=\(apk) exec app_process / cl.hazlo.puente.shell.Helper"]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { Log.info("no pude lanzar ayudante: \(error)"); return }
        Log.info("ayudante lanzado en \(dev.serial)")
        process = p
        stdin = inPipe.fileHandleForWriting
        device = dev
        buffer.removeAll()

        // Latido: si el celular deja de responder, se corta y se reintenta
        var lastSeen = Date()
        let beat = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        beat.schedule(deadline: .now() + 15, repeating: 15)
        beat.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(lastSeen) > 40 { p.terminate(); return }
            self.send(["t": "ping"])
            // Pasar al enlace propio apenas responda: no depende de adb y desenchufar no corta nada
            if let (ch, _, _) = self.connectNet(probe: true) {
                ch.close()
                Log.info("enlace propio disponible: dejando adb")
                self.send(["t": "adbWifi", "on": false]) // ya no hace falta (si estaba encendida)
                Thread.sleep(forTimeInterval: 0.3)
                p.terminate()
            } else if dev.isWifi {
                self.send(["t": "adbWifi", "on": true]) // seguimos necesitándola: que no se apague
            }
        }
        beat.resume()

        let reader = outPipe.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            lastSeen = Date()
            consume(chunk, wifi: dev.isWifi)
        }
        Log.info("ayudante terminó")
        beat.cancel()
        p.terminate()
        p.waitUntilExit()
        stdin = nil
        device = nil
        DispatchQueue.main.async { self.onState?(.searching) }
    }

    /// El mismo ayudante, por el enlace cifrado propio (hotspot o Wi‑Fi de casa).
    private func runNet(_ ch: NetChannel, host: String, kind: NetKind) {
        guard !paused else { ch.close(); return }
        Log.info(kind == .hotspot ? "enlace por hotspot" : "enlace por Wi‑Fi (\(host))")
        netKind = kind
        netHost = host
        net = ch
        viaNet = true
        buffer.removeAll()
        let beat = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        beat.schedule(deadline: .now() + 15, repeating: 15)
        beat.setEventHandler { [weak self] in self?.send(["t": "ping"]) }
        beat.resume()
        while let chunk = ch.read() {
            if paused { break }
            consume(chunk, wifi: true)
        }
        Log.info("enlace propio terminó")
        beat.cancel()
        ch.close()
        net = nil
        viaNet = false
        netKind = nil
        netHost = nil
        DispatchQueue.main.async { self.onState?(.searching) }
    }

    private func consume(_ chunk: Data, wifi: Bool) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                Log.info("línea no JSON: \(String(decoding: line.prefix(200), as: UTF8.self))"); continue }
            let t = obj["t"] as? String ?? "?"
            if t != "pong" { Log.info("← \(t)" + (t == "log" ? ": \(obj["d"] ?? "")" : "")) }
            if t == "hello" {
                // Su IP en el Wi‑Fi: para encontrarlo en casa sin adb
                if let ip = obj["ip"] as? String, !ip.isEmpty { UserDefaults.standard.set(ip, forKey: Self.phoneIPKey) }
                if let n = obj["name"] as? String, !n.isEmpty { UserDefaults.standard.set(n, forKey: "phoneName") }
                DispatchQueue.main.async { self.onState?(.connected(wifi: wifi)) }
            }
            DispatchQueue.main.async { self.onMessage?(obj) }
        }
    }

    // MARK: - Envío

    func send(_ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        if let h = stdin {
            do { try h.write(contentsOf: data) } catch { Log.info("error enviando: \(error)") }
        } else if let n = net {
            if !n.write(data) { Log.info("error enviando por hotspot") }
        } else { return }
        if obj["t"] as? String != "ping" { Log.info("→ \(obj["t"] ?? "?")") }
    }

    /// Imagen del Mac al celular: se sube el archivo y la app de Android la pone en el portapapeles.
    func sendImage(png: Data) {
        guard let dev = device else {
            if viaNet { send(["t": "clipImage", "name": "mac_\(Int(Date().timeIntervalSince1970 * 1000)).png",
                              "mime": "image/png", "b64": png.base64EncodedString()]) }
            return
        }
        DispatchQueue.global().async {
            let name = "mac_\(Int(Date().timeIntervalSince1970 * 1000)).png"
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            guard (try? png.write(to: tmp)) != nil else { return }
            defer { try? FileManager.default.removeItem(at: tmp) }
            let push = Adb.run(["-s", dev.serial, "push", tmp.path, "\(Self.phoneClipDir)/\(name)"], timeout: 60)
            guard push.status == 0 else { return }
            _ = Adb.shell(dev.serial,
                "am broadcast -n \(Self.package)/.ClipReceiver --es file \(name) --es mime image/png")
        }
    }
}
