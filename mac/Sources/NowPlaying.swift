import Foundation

/// "Ahora suena" del Mac. MediaRemote solo responde a procesos de Apple, así que el lector
/// (Resources/nowplaying.dylib) corre dentro de /usr/bin/perl y habla por líneas JSON.
final class NowPlaying {
    /// Último estado tal como lo entrega el lector (con "art" solo cuando cambió la carátula).
    private(set) var latest: [String: Any]?
    /// Última carátula en base64, para reenviarla al reconectar el celular.
    private(set) var latestArt: String?
    var onUpdate: (([String: Any]) -> Void)?

    private let queue = DispatchQueue(label: "puente.nowplaying")
    private var process: Process?
    private var stdin: FileHandle?
    private var stopped = false

    func start() { queue.async { self.loop() } }

    func stop() { stopped = true; process?.terminate() }

    /// Comandos: toggle, play, pause, next, prev; seek con "to" en segundos.
    func command(_ c: String, to: Double? = nil) {
        var obj: [String: Any] = ["c": c]
        if let to { obj["to"] = to }
        guard let h = stdin, var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        try? h.write(contentsOf: data)
    }

    /// Estado completo (con carátula) para mandar a un celular recién conectado.
    var snapshot: [String: Any]? {
        guard var m = latest else { return nil }
        if m["art"] == nil, let a = latestArt { m["art"] = a }
        return m
    }

    private func loop() {
        guard let res = Bundle.main.resourcePath,
              FileManager.default.fileExists(atPath: res + "/nowplaying.dylib") else {
            Log.info("nowplaying: falta el lector en Resources"); return
        }
        while !stopped {
            run(script: res + "/nowplaying.pl", lib: res + "/nowplaying.dylib")
            Thread.sleep(forTimeInterval: 3)
        }
    }

    private func run(script: String, lib: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script, lib]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { Log.info("nowplaying: \(error)"); return }
        process = p
        stdin = inPipe.fileHandleForWriting

        var buffer = Data()
        let reader = outPipe.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                switch obj["t"] as? String {
                case "np":
                    if obj["none"] as? Bool == true { latestArt = nil }
                    else if let a = obj["art"] as? String { latestArt = a }
                    else if (obj["artKey"] as? String ?? "").isEmpty { latestArt = nil }
                    latest = obj
                    DispatchQueue.main.async { self.onUpdate?(obj) }
                case "error":
                    Log.info("nowplaying: \(obj["d"] ?? "")"); stopped = true
                default: break
                }
            }
        }
        stdin = nil
        p.waitUntilExit()
        Log.info("nowplaying: lector terminó (\(p.terminationStatus))")
    }
}
