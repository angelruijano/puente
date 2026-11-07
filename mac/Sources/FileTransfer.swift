import AppKit

/// Archivos entre el Mac y el celular, estilo AirDrop: por el enlace propio en binario, o por adb con cable.
/// Mac → celular: Descargas del celular. Celular → Mac: ~/Downloads.
final class FileTransfer: NSObject, NSWindowDelegate {
    private let link: PhoneLink
    private let q = DispatchQueue(label: "puente.files")
    /// Estado para el menú: nil = nada en curso
    var onStatus: ((String?) -> Void)?
    private var incoming: [String: [URL]] = [:]  // carpeta del celular → archivos ya traídos
    private weak var button: NSStatusBarButton?

    init(link: PhoneLink) { self.link = link }

    // MARK: Mac → celular

    func send(_ urls: [URL]) {
        let files = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }
        let serial = link.device?.serial
        guard serial != nil || link.viaNet else {
            Toast.show("Tu celular no está conectado", "No se pudo enviar \(Self.describe(files))"); return
        }
        q.async { [self] in
            let start = Date()
            var paths: [String] = []
            var fc: NetChannel?
            if serial == nil {
                guard let host = link.netHost, let c = NetChannel.connect(host: host, purpose: "files") else {
                    status(nil); Toast.show("No se pudo enviar al celular", Self.describe(files)); return }
                fc = c
            }
            defer { fc?.close() }
            for (i, f) in files.enumerated() {
                status(files.count == 1 ? "Enviando \(f.lastPathComponent)…" : "Enviando \(i + 1) de \(files.count)…")
                if let serial {
                    let dest = uniquePhonePath(serial, f.lastPathComponent)
                    let r = Adb.run(["-s", serial, "push", f.path, dest], timeout: 3600)
                    if r.out.contains("pushed"), !r.out.contains("error") { paths.append(dest) }
                    else { Log.info("push falló: \(r.out.suffix(200))") }
                } else if let fc, let p = netSend(fc, f, label: files.count == 1 ? nil : "\(i + 1) de \(files.count)") {
                    paths.append(p)
                }
            }
            status(nil)
            if paths.isEmpty {
                Toast.show("No se pudo enviar al celular", Self.describe(files)); return
            }
            let name = (paths.first.map { ($0 as NSString).lastPathComponent }) ?? ""
            link.send(["t": "fileIn", "paths": paths, "name": name, "count": paths.count, "scanned": serial == nil])
            let secs = Date().timeIntervalSince(start)
            Toast.show("Enviado a tu celular", "\(Self.describe(files)) · en Descargas" + (secs > 3 ? " · \(Int(secs)) s" : ""))
        }
    }

    /// Descargas del celular, sin pisar un archivo con el mismo nombre.
    private func uniquePhonePath(_ serial: String, _ name: String) -> String {
        let clean = name.replacingOccurrences(of: "/", with: "_")
        let ext = (clean as NSString).pathExtension
        let base = (clean as NSString).deletingPathExtension
        var candidate = clean
        var n = 2
        while Adb.shell(serial, "test -e \(Self.quote("/sdcard/Download/" + candidate)) && echo si", timeout: 5)
                .contains("si") && n < 100 {
            candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            n += 1
        }
        return "/sdcard/Download/" + candidate
    }

    // MARK: Por el enlace propio (sin adb): binario, en una conexión aparte

    private static let chunk = 1024 * 1024
    private let rq = DispatchQueue(label: "puente.files.in")

    /// Archivo o carpeta completa a Descargas del celular; devuelve dónde quedó.
    private func netSend(_ ch: NetChannel, _ f: URL, label: String?) -> String? {
        let isDir = (try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        guard isDir else { return netPut(ch, f, dir: nil, rel: nil, label: label) }
        guard ch.send(json: ["op": "mkdir", "name": f.lastPathComponent]),
              let r = ch.readJSON(), r["ok"] as? Bool == true, let dir = r["path"] as? String else { return nil }
        let base = f.standardizedFileURL.path
        let items = FileManager.default.enumerator(at: f, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true } ?? []
        for (i, item) in items.enumerated() {
            let rel = String(item.standardizedFileURL.path.dropFirst(base.count + 1))
            guard netPut(ch, item, dir: dir, rel: rel, label: "\(f.lastPathComponent): \(i + 1) de \(items.count)") != nil else { return nil }
        }
        return dir
    }

    private func netPut(_ ch: NetChannel, _ f: URL, dir: String?, rel: String?, label: String?) -> String? {
        guard let h = try? FileHandle(forReadingFrom: f) else { return nil }
        defer { try? h.close() }
        let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var req: [String: Any] = ["op": "put", "size": size]
        if let dir, let rel { req["dir"] = dir; req["rel"] = rel } else { req["name"] = f.lastPathComponent }
        guard ch.send(json: req) else { return nil }
        var sent = 0, lastPct = -1
        while sent < size {
            guard let d = try? h.read(upToCount: min(Self.chunk, size - sent)), !d.isEmpty, ch.write(d) else { return nil }
            sent += d.count
            let pct = sent * 100 / max(size, 1)
            if size > 4 * Self.chunk, pct / 5 != lastPct / 5 {
                lastPct = pct
                status("Enviando \(label ?? f.lastPathComponent)… \(pct) %")
            }
        }
        guard let r = ch.readJSON(), r["ok"] as? Bool == true else { return nil }
        return r["path"] as? String
    }

    /// Archivo del celular → destino en el Mac.
    private func netGet(_ path: String, to dest: URL, name: String) -> Bool {
        guard let host = link.netHost, let ch = NetChannel.connect(host: host, purpose: "files") else { return false }
        defer { ch.close() }
        guard ch.send(json: ["op": "get", "path": path]), let r = ch.readJSON(), r["ok"] as? Bool == true,
              let size = (r["size"] as? NSNumber)?.intValue,
              FileManager.default.createFile(atPath: dest.path, contents: nil),
              let h = try? FileHandle(forWritingTo: dest) else { return false }
        defer { try? h.close() }
        var got = 0, lastPct = -1
        while got < size {
            guard let d = ch.read() else { try? FileManager.default.removeItem(at: dest); return false }
            h.write(d)
            got += d.count
            let pct = got * 100 / max(size, 1)
            if size > 4 * Self.chunk, pct / 5 != lastPct / 5 { lastPct = pct; status("Recibiendo \(name)… \(pct) %") }
        }
        return true
    }

    // MARK: celular → Mac

    func receive(_ m: [String: Any]) {
        guard let path = m["path"] as? String, let dir = m["dir"] as? String,
              path.hasPrefix("/storage/emulated/0/Android/data/cl.hazlo.puente/") else { return }
        let name = (m["name"] as? String).map { $0.replacingOccurrences(of: "/", with: "_") } ?? "archivo"
        let count = m["count"] as? Int ?? 1
        let serial = link.device?.serial
        guard serial != nil || link.viaNet else { return }
        rq.async { [self] in
            status(count == 1 ? "Recibiendo \(name)…" : "Recibiendo \((incoming[dir]?.count ?? 0) + 1) de \(count)…")
            let dest = Self.unique(Self.downloads.appendingPathComponent(name))
            if let serial {
                let r = Adb.run(["-s", serial, "pull", path, dest.path], timeout: 3600)
                if !FileManager.default.fileExists(atPath: dest.path) { Log.info("pull falló: \(r.out.suffix(200))") }
                finishOne(dir: dir, dest: dest, name: name, count: count, serial: serial)
            } else {
                if !netGet(path, to: dest, name: name) { Log.info("no llegó por el enlace: \(name)") }
                finishOne(dir: dir, dest: dest, name: name, count: count, serial: nil)
            }
        }
    }

    /// Un archivo del lote terminó (o falló): al completar el lote, avisar y limpiar en el celular.
    private func finishOne(dir: String, dest: URL, name: String, count: Int, serial: String?) {
        let ok = FileManager.default.fileExists(atPath: dest.path)
        if ok {
            incoming[dir, default: []].append(dest)
            // Como Safari/AirDrop: la pila de Descargas del Dock rebota
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: dest.path)
        }
        guard (incoming[dir]?.count ?? 0) >= count || !ok else { return }
        let got = incoming.removeValue(forKey: dir) ?? []
        status(nil)
        if let serial { _ = Adb.shell(serial, "rm -rf \(Self.quote(dir))", timeout: 10) }
        else { link.send(["t": "frm", "dir": dir]) }
        if got.isEmpty { Toast.show("No llegó el archivo del celular", name); return }
        let isImage = got.count == 1 && ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(got[0].pathExtension.lowercased())
        Toast.show("Recibido del celular", "\(Self.describe(got)) · en Descargas",
                   image: isImage ? got[0] : nil,
                   info: ["path": got.count == 1 ? got[0].path : Self.downloads.path])
    }

    private static var downloads: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

    // MARK: Soltar archivos en el ícono de la barra de menú

    func attach(to item: NSStatusItem) {
        button = item.button
        guard let w = item.button?.window else { return }
        w.registerForDraggedTypes([.fileURL])
        w.delegate = self
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard link.isConnected, !urls(sender).isEmpty else { return [] }
        button?.highlight(true)
        return .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        button?.highlight(false)
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        button?.highlight(false)
        let u = urls(sender)
        guard !u.isEmpty else { return false }
        send(u)
        return true
    }

    private func urls(_ d: NSDraggingInfo) -> [URL] {
        d.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    // MARK: Utilidades

    func pick() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.prompt = "Enviar"
        p.message = "Elige lo que quieres mandar a Descargas de tu celular"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK { send(p.urls) }
    }

    private func status(_ s: String?) { DispatchQueue.main.async { self.onStatus?(s) } }

    static func describe(_ urls: [URL]) -> String {
        urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) archivos"
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func unique(_ url: URL) -> URL {
        var u = url
        let ext = url.pathExtension, base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while FileManager.default.fileExists(atPath: u.path) {
            u = url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return u
    }
}
