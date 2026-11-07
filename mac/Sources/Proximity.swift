import AppKit
import CoreBluetooth
import CryptoKit

/// Llaves y datos del hotspot. Archivo con permisos 600 (el llavero pediría permiso en cada compilación ad‑hoc).
enum Secrets {
    private static var url: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Puente")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("secrets.json")
    }
    private static func load() -> [String: String] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: String] ?? [:]
    }
    static func get(_ k: String) -> String? { load()[k] }
    static func set(_ k: String, _ v: String) {
        var d = load(); d[k] = v
        guard let data = try? JSONSerialization.data(withJSONObject: d) else { return }
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }
    /// Llave compartida con el celular para el Bluetooth (se crea una vez).
    static var bleKey: Data {
        if let h = get("bleKey"), let d = Data(hex: h) { return d }
        let d = Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
        set("bleKey", d.hex)
        return d
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    init?(hex: String) {
        var d = Data(); var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            d.append(b); i = j
        }
        self = d
    }
}

/// Distancia al celular por Bluetooth; bloquea el Mac al alejarse (nunca desbloquea).
/// También envía comandos firmados al celular (hotspot) aunque no compartan Wi‑Fi.
final class Proximity: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum Sensitivity: Int, CaseIterable { case near = 0, medium, far
        var threshold: Double { [-62.0, -72.0, -82.0][rawValue] }
        var label: String { ["Cerca", "Media", "Lejos"][rawValue] }
    }
    struct Status: Equatable { var seen = false; var near = false; var rssi: Int? = nil; var bluetoothOn = true }

    static let service = CBUUID(string: "6b1f3a52-9d2e-4c47-8a51-50756e746531")
    static let command = CBUUID(string: "6b1f3a52-9d2e-4c47-8a51-50756e746532")
    private static let window: TimeInterval = 900
    private static let lockDelay: TimeInterval = 10

    var lockEnabled = true
    var sensitivity = Sensitivity.medium
    /// El celular avisó (por Wi‑Fi) que apagó su Bluetooth: no bloquear por falta de señal.
    var phoneBluetoothOn = true
    var onStatus: ((Status) -> Void)?

    private let key = Secrets.bleKey
    private var central: CBCentralManager!
    private var samples: [(Date, Int)] = []
    private var lastSeen: Date?
    private var armed = false
    private var awaySince: Date?
    private var timer: Timer?
    private(set) var phone: CBPeripheral?
    private var pending: (cmd: UInt8, done: (Bool) -> Void)?
    private(set) var status = Status()

    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.evaluate() }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.disarm() }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.disarm() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.disarm() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.samples.removeAll(); self?.disarm()
        }
    }

    /// Tras bloquear, despertar o desbloquear: no volver a bloquear hasta ver el celular cerca otra vez.
    private func disarm() { armed = false; awaySince = nil }

    // MARK: Escaneo

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        Log.info("bluetooth: estado \(c.state.rawValue), permiso \(CBManager.authorization.rawValue)")
        if c.state == .poweredOn {
            c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
        publish()
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        guard let m = ad[CBAdvertisementDataManufacturerDataKey] as? Data, m.count == 12,
              m[m.startIndex] == 0xFF, m[m.startIndex + 1] == 0xFF,
              m[m.startIndex + 2] == UInt8(ascii: "P"), m[m.startIndex + 3] == 1,
              valid(token: m.subdata(in: (m.startIndex + 4)..<(m.startIndex + 12))) else { return }
        let r = rssi.intValue
        guard r < 0, r > -110 else { return }
        phone = p
        lastSeen = Date()
        samples.append((Date(), r))
    }

    private func valid(token: Data) -> Bool {
        let w = Int64(Date().timeIntervalSince1970 / Self.window)
        // Tolerar relojes desfasados y que el celular dormido cambie tarde el identificador
        for d in -4...1 where Self.token(key: key, window: w + Int64(d)) == token { return true }
        return false
    }

    private static func token(key: Data, window: Int64) -> Data {
        var msg = Data([UInt8(ascii: "P")])
        withUnsafeBytes(of: window.bigEndian) { msg.append(contentsOf: $0) }
        return Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key))).prefix(8)
    }

    // MARK: Decisión

    private func evaluate() {
        let now = Date()
        samples.removeAll { now.timeIntervalSince($0.0) > 8 }
        let seen = lastSeen.map { now.timeIntervalSince($0) < 20 } ?? false
        let rssi = median(samples.map(\.1))
        let near = seen && Double(rssi ?? -200) >= sensitivity.threshold

        if near {
            armed = true; awaySince = nil
        } else if armed, lockEnabled, phoneBluetoothOn, central.state == .poweredOn {
            if awaySince == nil { awaySince = now }
            if let a = awaySince, now.timeIntervalSince(a) >= Self.lockDelay, !Self.screenLocked {
                Log.info("proximidad: celular lejos (\(rssi.map { "\($0) dBm" } ?? "sin señal")), bloqueando")
                Self.lockScreen()
                disarm()
            }
        }
        let new = Status(seen: seen, near: near, rssi: rssi, bluetoothOn: central.state == .poweredOn)
        if new.seen != status.seen || new.near != status.near {
            Log.info("proximidad: \(new.seen ? (new.near ? "cerca" : "lejos") : "sin señal")\(rssi.map { " (\($0) dBm)" } ?? "")")
        }
        status = new
        publish()
    }

    private func publish() { onStatus?(status) }

    private func median(_ v: [Int]) -> Int? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted(); return s[s.count / 2]
    }

    static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Igual que ⌃⌘Q
    static func lockScreen() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
              let sym = dlsym(h, "SACLockScreenImmediate") else { return }
        typealias Fn = @convention(c) () -> Int32
        _ = unsafeBitCast(sym, to: Fn.self)()
    }

    // MARK: Comandos al celular (1 = hotspot on, 2 = off)

    func send(command cmd: UInt8, done: @escaping (Bool) -> Void) {
        guard let p = phone, central.state == .poweredOn else { done(false); return }
        pending = (cmd, done)
        p.delegate = self
        central.connect(p)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.finish(false) }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices([Self.service]) }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { finish(false) }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == Self.service }) else { finish(false); return }
        p.discoverCharacteristics([Self.command], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let ch = s.characteristics?.first(where: { $0.uuid == Self.command }), let cmd = pending?.cmd else {
            finish(false); return }
        let ts = Int64(Date().timeIntervalSince1970)
        var msg = Data([UInt8(ascii: "C"), cmd])
        withUnsafeBytes(of: ts.bigEndian) { msg.append(contentsOf: $0) }
        let mac = Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key))).prefix(16)
        var packet = Data([cmd])
        withUnsafeBytes(of: ts.bigEndian) { packet.append(contentsOf: $0) }
        packet.append(mac)
        p.writeValue(packet, for: ch, type: .withResponse)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if let error { Log.info("bluetooth: comando rechazado (\(error.localizedDescription))") }
        finish(error == nil)
    }

    private func finish(_ ok: Bool) {
        guard let pend = pending else { return }
        pending = nil
        if let p = phone { central.cancelPeripheralConnection(p) }
        pend.done(ok)
    }
}

/// Hotspot instantáneo: el celular lo enciende por Bluetooth y el Mac se conecta solo.
final class Hotspot {
    enum State: Equatable { case idle, connecting, connected, failed(String) }
    var onState: ((State) -> Void)?
    private(set) var state = State.idle { didSet { onState?(state) } }
    private let proximity: Proximity

    init(proximity: Proximity) { self.proximity = proximity }

    var hasCredentials: Bool { Secrets.get("hotspotSSID") != nil }

    func saveCredentials(ssid: String, pass: String) {
        guard !ssid.isEmpty else { return }
        Secrets.set("hotspotSSID", ssid); Secrets.set("hotspotPass", pass)
    }

    func connect() {
        guard let ssid = Secrets.get("hotspotSSID") else { state = .failed("Conecta Puente una vez en casa"); return }
        let pass = Secrets.get("hotspotPass") ?? ""
        state = .connecting
        proximity.send(command: 1) { [weak self] ok in
            guard let self else { return }
            guard ok else { self.state = .failed("El celular no respondió por Bluetooth"); return }
            DispatchQueue.global().async { self.join(ssid: ssid, pass: pass) }
        }
    }

    func disconnect() {
        proximity.send(command: 2) { _ in }
        state = .idle // el Mac vuelve solo a su red conocida
    }

    private func join(ssid: String, pass: String) {
        let dev = Self.wifiDevice()
        for _ in 0..<12 { // el hotspot tarda unos segundos en aparecer
            Thread.sleep(forTimeInterval: 2.5)
            let out = Self.run("/usr/sbin/networksetup", ["-setairportnetwork", dev, ssid, pass])
            if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Log.info("hotspot: conectado")
                DispatchQueue.main.async { self.state = .connected }
                return
            }
        }
        DispatchQueue.main.async { self.state = .failed("No pude unirme al hotspot") }
    }

    private static func wifiDevice() -> String {
        let out = run("/usr/sbin/networksetup", ["-listallhardwareports"])
        let lines = out.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.contains("Wi-Fi") }), i + 1 < lines.count,
           let dev = lines[i + 1].components(separatedBy: ": ").last { return dev }
        return "en0"
    }

    @discardableResult
    private static func run(_ exe: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try? p.run(); p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
