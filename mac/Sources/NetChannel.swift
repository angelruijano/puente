import CryptoKit
import Darwin
import Foundation

/// Enlace cifrado propio con el celular, sin adb: por su hotspot o por el Wi‑Fi de casa.
/// Mismo protocolo que NetLink.java: llaves efímeras X25519 + llave compartida (HKDF) y marcos AES‑256‑GCM.
final class NetChannel {
    static let port: UInt16 = 47930
    private static let magic = Data("PNT2".utf8)

    private let fd: Int32
    private let tx: SymmetricKey
    private let rx: SymmetricKey
    private var txCounter: UInt64 = 0
    private var rxCounter: UInt64 = 0
    private let wlock = NSLock()

    /// Llave compartida, creada una vez en el Mac y copiada al celular por adb (en casa).
    static var key: Data {
        if let h = Secrets.get("netKey"), let d = Data(hex: h), d.count == 32 { return d }
        let d = Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
        Secrets.set("netKey", d.hex)
        return d
    }

    private init(fd: Int32, tx: SymmetricKey, rx: SymmetricKey) { self.fd = fd; self.tx = tx; self.rx = rx }

    deinit { Darwin.close(fd) }

    /// Corta la conexión (el lector sale de read() con nil).
    func close() { Darwin.shutdown(fd, SHUT_RDWR) }

    static func connect(host: String, purpose: String = "puente", port: UInt16 = NetChannel.port, timeout: TimeInterval = 3) -> NetChannel? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { return nil }
        defer { freeaddrinfo(res) }
        let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

        // Conectar con tiempo límite
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
        if rc != 0 && errno != EINPROGRESS { Darwin.close(fd); return nil }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) == 1 else { Darwin.close(fd); return nil }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        guard err == 0 else { Darwin.close(fd); return nil }
        _ = fcntl(fd, F_SETFL, flags)
        setTimeout(fd, 10)

        // Saludo: llave efímera + nonce de cada lado
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let cpub = eph.publicKey.rawRepresentation
        var nc = Data(count: 16)
        _ = nc.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard writeAll(fd, magic + cpub + nc), let reply = readExact(fd, 52), reply.prefix(4) == magic else {
            Darwin.close(fd); return nil }
        let spub = reply.subdata(in: reply.startIndex + 4 ..< reply.startIndex + 36)
        let ns = reply.suffix(16)
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: spub),
              let dh = try? eph.sharedSecretFromKeyAgreement(with: peer) else { Darwin.close(fd); return nil }
        let dhBytes = dh.withUnsafeBytes { Data($0) }
        guard dhBytes != Data(count: 32) else { Darwin.close(fd); return nil }
        let salt = nc + ns + cpub + spub
        let ikm = SymmetricKey(data: key + dhBytes)
        let c2s = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("puente2 c2s".utf8), outputByteCount: 32)
        let s2c = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("puente2 s2c".utf8), outputByteCount: 32)
        let ch = NetChannel(fd: fd, tx: c2s, rx: s2c)
        // Pedimos sesión o archivos; el celular responde "ok" (prueba de que también tiene la llave)
        guard ch.write(Data(purpose.utf8)), ch.read() == Data("ok".utf8) else { return nil }
        setTimeout(fd, purpose == "files" ? 120 : 45) // sesión: el Mac manda un latido cada 15 s
        return ch
    }

    @discardableResult
    func write(_ plain: Data) -> Bool {
        wlock.lock(); defer { wlock.unlock() }
        guard let box = try? AES.GCM.seal(plain, using: tx, nonce: Self.nonce(&txCounter)) else { return false }
        let body = box.ciphertext + box.tag
        var len = UInt32(body.count).bigEndian
        return Self.writeAll(fd, Data(bytes: &len, count: 4) + body)
    }

    /// Siguiente marco descifrado; nil si se cortó o alguien lo alteró.
    func read() -> Data? {
        guard let h = Self.readExact(fd, 4) else { return nil }
        let n = Int(h.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        guard n >= 16, n <= 8 * 1024 * 1024, let body = Self.readExact(fd, n) else { return nil }
        guard let box = try? AES.GCM.SealedBox(nonce: Self.nonce(&rxCounter), ciphertext: body.prefix(n - 16), tag: body.suffix(16)),
              let plain = try? AES.GCM.open(box, using: rx) else { return nil }
        return plain
    }

    private static func nonce(_ c: inout UInt64) -> AES.GCM.Nonce {
        var be = c.bigEndian
        c += 1
        return try! AES.GCM.Nonce(data: Data(count: 4) + Data(bytes: &be, count: 8))
    }

    private static func setTimeout(_ fd: Int32, _ secs: Int) {
        var tv = timeval(tv_sec: secs, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func writeAll(_ fd: Int32, _ d: Data) -> Bool {
        d.withUnsafeBytes { p in
            var off = 0
            while off < d.count {
                let w = Darwin.write(fd, p.baseAddress! + off, d.count - off)
                if w <= 0 { return false }
                off += w
            }
            return true
        }
    }

    private static func readExact(_ fd: Int32, _ n: Int) -> Data? {
        var d = Data(count: n)
        var off = 0
        let ok = d.withUnsafeMutableBytes { p -> Bool in
            while off < n {
                let r = Darwin.read(fd, p.baseAddress! + off, n - off)
                if r <= 0 { return false }
                off += r
            }
            return true
        }
        return ok ? d : nil
    }

    /// JSON por el canal (pedidos de archivos)
    func send(json: [String: Any]) -> Bool {
        guard let d = try? JSONSerialization.data(withJSONObject: json) else { return false }
        return write(d)
    }

    func readJSON() -> [String: Any]? {
        guard let d = read() else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    /// Router del Wi‑Fi del Mac: en el hotspot, es el celular. (No la ruta por defecto: una VPN la cambia.)
    static func gateway() -> String? {
        let ports = run("/usr/sbin/networksetup", ["-listallhardwareports"]).components(separatedBy: "\n")
        var dev = "en0"
        if let i = ports.firstIndex(where: { $0.contains("Wi-Fi") }), i + 1 < ports.count,
           let d = ports[i + 1].components(separatedBy: ": ").last { dev = d.trimmingCharacters(in: .whitespaces) }
        let r = run("/usr/sbin/ipconfig", ["getoption", dev, "router"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return r.first?.isNumber == true ? r : nil
    }

    private static func run(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return out
    }
}
