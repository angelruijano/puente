import Foundation

/// Envoltorio mínimo de adb. Todo corre fuera del hilo principal.
enum Adb {
    static let path: String = {
        let candidates = [
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "adb"
    }()

    struct Device: Equatable {
        let serial: String
        let model: String
        var isWifi: Bool { serial.contains(":") || serial.contains("_adb-tls-connect") }
        /// adb tcpip 5555: sin cifrar, no lo usamos
        var isLegacyTCP: Bool { serial.hasSuffix(":5555") }
    }

    @discardableResult
    static func run(_ args: [String], timeout: TimeInterval = 15) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "\(error)") }
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func devices() -> [Device] {
        run(["devices", "-l"]).out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[1] == "device" else { return nil }
            let model = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)) } ?? "?"
            return Device(serial: String(parts[0]), model: model)
        }
    }

    /// Conecta a celulares emparejados que anuncian depuración inalámbrica (TLS) por mDNS.
    /// La búsqueda Bonjour la hace Puente (tiene el permiso de red local); el adb que lanza una app
    /// de la barra de menú a veces no ve nada.
    static func connectWireless() {
        // macOS a veces le niega la red local al servidor adb lanzado por Puente ("No route to host"):
        // Puente reenvía desde 127.0.0.1 (adb sigue cifrando con TLS de punta a punta).
        // Reenvíos viejos (la depuración inalámbrica cambia de puerto cada vez que se enciende)
        for line in run(["devices"]).out.split(separator: "\n") where line.hasPrefix("127.0.0.1:") && line.hasSuffix("offline") {
            run(["disconnect", String(line.split(separator: "\t")[0])], timeout: 3)
        }
        let known = Set(devices().map(\.serial))
        for addr in Bonjour.find("_adb-tls-connect._tcp.", timeout: 2.5) {
            guard let local = Relay.local(for: addr), !known.contains(local) else { continue }
            run(["connect", local], timeout: 5)
        }
        let services = run(["mdns", "services"], timeout: 5).out
        for line in services.split(separator: "\n") where line.contains("_adb-tls-connect") {
            if let addr = line.split(separator: "\t").map({ $0.trimmingCharacters(in: .whitespaces) })
                .last(where: { $0.contains(":") && $0.first?.isNumber == true }) {
                run(["connect", addr], timeout: 5)
            }
        }
    }

    static func shell(_ serial: String, _ cmd: String, timeout: TimeInterval = 15) -> String {
        run(["-s", serial, "shell", cmd], timeout: timeout).out
    }
}

/// Búsqueda Bonjour síncrona (en un hilo propio con su run loop): devuelve "ip:puerto" IPv4.
final class Bonjour: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private var found: [NetService] = []
    private var addrs = Set<String>()

    static func find(_ type: String, timeout: TimeInterval) -> [String] {
        let b = Bonjour()
        let done = DispatchSemaphore(value: 0)
        let t = Thread {
            let browser = NetServiceBrowser()
            browser.delegate = b
            browser.searchForServices(ofType: type, inDomain: "local.")
            RunLoop.current.run(until: Date().addingTimeInterval(timeout))
            browser.stop()
            b.found.forEach { $0.stop() }
            done.signal()
        }
        t.start()
        done.wait()
        return Array(b.addrs)
    }

    func netServiceBrowser(_ b: NetServiceBrowser, didFind s: NetService, moreComing: Bool) {
        found.append(s)
        s.delegate = self
        s.resolve(withTimeout: 2)
    }

    func netServiceDidResolveAddress(_ s: NetService) {
        for data in s.addresses ?? [] {
            data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
                guard let sa = p.baseAddress?.assumingMemoryBound(to: sockaddr.self), sa.pointee.sa_family == sa_family_t(AF_INET) else { return }
                let sin = p.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var a = sin.sin_addr
                inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
                addrs.insert("\(String(cString: buf)):\(UInt16(bigEndian: sin.sin_port))")
            }
        }
    }
}

/// Reenvío TCP 127.0.0.1:puerto → celular, uno por dirección remota, vivo mientras corra Puente.
enum Relay {
    private static var relays: [String: String] = [:]
    private static let lock = NSLock()

    static func local(for remote: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let l = relays[remote] { return l }
        let parts = remote.split(separator: ":")
        guard parts.count == 2, let rport = UInt16(parts[1]) else { return nil }
        let host = String(parts[0])
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        a.sin_port = 0
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
        guard ok, listen(fd, 4) == 0 else { close(fd); return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let lport = UInt16(bigEndian: a.sin_port)
        Thread.detachNewThread {
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { continue }
                Thread.detachNewThread { bridge(c, host: host, port: rport) }
            }
        }
        let l = "127.0.0.1:\(lport)"
        relays[remote] = l
        return l
    }

    private static func bridge(_ c: Int32, host: String, port: UInt16) {
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let r = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr(host)
        a.sin_port = port.bigEndian
        setsockopt(r, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(r, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(r, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
        guard ok else { close(r); close(c); return }
        let done = DispatchGroup()
        for (from, to) in [(c, r), (r, c)] {
            done.enter()
            Thread.detachNewThread {
                var buf = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = read(from, &buf, buf.count)
                    if n <= 0 { break }
                    var off = 0
                    while off < n {
                        let w = buf.withUnsafeBytes { write(to, $0.baseAddress! + off, n - off) }
                        if w <= 0 { break }
                        off += w
                    }
                    if off < n { break }
                }
                shutdown(to, SHUT_WR); shutdown(from, SHUT_RD)
                done.leave()
            }
        }
        done.wait()
        close(r); close(c)
    }
}
