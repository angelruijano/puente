import AppKit
import Intents
import SwiftUI
import UserNotifications

// MARK: - Ver el celular en el Mac (scrcpy por el mismo canal cifrado de adb)

final class Mirror {
    private var process: Process?
    var onChange: ((Bool) -> Void)?
    var running: Bool { process?.isRunning == true }

    static let path: String? = ["/opt/homebrew/bin/scrcpy", "/usr/local/bin/scrcpy"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    func open(serial: String) {
        if let p = process, p.isRunning {
            NSRunningApplication(processIdentifier: p.processIdentifier)?.activate()
            return
        }
        guard let exe = Self.path else { Log.info("scrcpy no está instalado"); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["-s", serial, "--window-title", UserDefaults.standard.string(forKey: "phoneName") ?? "Tu celular",
                       "--turn-screen-off",       // la pantalla del celular se apaga mientras lo usas desde el Mac
                       "--keyboard=uhid",         // teclado del Mac como teclado físico (tildes, ñ, atajos)
                       "--video-bit-rate=12M", "--max-fps=60"]
                       // el sonido del celular sale por el Mac mientras la ventana está abierta, como en el iPhone
        var env = ProcessInfo.processInfo.environment
        env["ADB"] = Adb.path
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.onChange?(false) } }
        do { try p.run(); process = p; onChange?(true) } catch { Log.info("scrcpy: \(error)") }
        // Traer la ventana al frente cuando aparezca
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSRunningApplication(processIdentifier: p.processIdentifier)?.activate()
        }
    }

    func close() { process?.terminate(); process = nil }
}

// MARK: - No molestar sincronizado

final class FocusSync {
    var onMacChange: ((Bool) -> Void)?
    private(set) var macOn: Bool?
    private var timer: Timer?

    func start() {
        INFocusStatusCenter.default.requestAuthorization { st in
            Log.info("concentración: permiso \(st.rawValue)")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func poll() {
        guard INFocusStatusCenter.default.authorizationStatus == .authorized,
              let on = INFocusStatusCenter.default.focusStatus.isFocused else { return }
        if on != macOn {
            let first = macOn == nil
            macOn = on
            if !first { onMacChange?(on) }
        }
    }

    static let shortcutOn = "Puente No molestar sí"
    static let shortcutOff = "Puente No molestar no"

    static var shortcutsInstalled: Bool {
        let out = Self.runShortcuts(["list"])
        return out.contains(shortcutOn) && out.contains(shortcutOff)
    }

    /// Cambiar la concentración del Mac (macOS solo lo permite por Atajos).
    func setMac(_ on: Bool) {
        macOn = on
        // Atajos guarda el nombre con la tilde descompuesta (venía del nombre de archivo): hay que pedirlo igual
        let name = (on ? Self.shortcutOn : Self.shortcutOff).decomposedStringWithCanonicalMapping
        DispatchQueue.global().async { _ = Self.runShortcuts(["run", name]) }
    }

    /// Abre los dos atajos para que la persona los añada (una vez).
    static func installShortcuts() {
        guard let res = Bundle.main.resourceURL else { return }
        for (file, name) in [("on", shortcutOn), ("off", shortcutOff)] {
            let src = res.appendingPathComponent("\(file).shortcut")
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).shortcut")
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
            NSWorkspace.shared.open(dst)
        }
    }

    private static func runShortcuts(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: - Pestaña del navegador → celular

enum BrowserTab {
    private(set) static var lastApp: NSRunningApplication?

    static func track() {
        lastApp = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               a.bundleIdentifier != Bundle.main.bundleIdentifier { lastApp = a }
        }
    }

    /// URL de la pestaña activa del último navegador usado.
    static func current() -> (url: String?, error: String?) {
        let candidates = [lastApp, NSWorkspace.shared.frontmostApplication].compactMap { $0 }
        guard let app = candidates.first(where: { scriptFor($0.bundleIdentifier ?? "") != nil }),
              let src = scriptFor(app.bundleIdentifier ?? "") else {
            return (nil, "Abre la página en Chrome, Opera, Safari, Brave, Edge o Arc")
        }
        var err: NSDictionary?
        let out = NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue
        if let out, out.hasPrefix("http") { return (out, nil) }
        Log.info("pestaña: \(err ?? [:])")
        return (nil, "Permite que Puente controle \(app.localizedName ?? "el navegador") en Ajustes › Privacidad › Automatización")
    }

    private static func scriptFor(_ id: String) -> String? {
        switch id {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            return "tell application id \"\(id)\" to get URL of front document"
        case "com.google.Chrome", "com.google.Chrome.beta", "com.brave.Browser", "com.microsoft.edgemac",
             "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.operasoftware.OperaGX", "company.thebrowser.Browser":
            return "tell application id \"\(id)\" to get URL of active tab of front window"
        default: return nil
        }
    }
}

// MARK: - Avisos breves del propio Puente

enum Toast {
    static func show(_ title: String, _ body: String = "", image: URL? = nil, info: [String: String] = [:]) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.userInfo = info.merging(["kind": "puente"]) { a, _ in a }
        if let image {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("puente-\(UUID().uuidString)." + image.pathExtension)
            if (try? FileManager.default.copyItem(at: image, to: tmp)) != nil,
               let a = try? UNNotificationAttachment(identifier: "img", url: tmp, options: nil) { c.attachments = [a] }
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
