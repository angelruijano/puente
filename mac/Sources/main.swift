import AppKit
import IOKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let link = PhoneLink()
    private lazy var clipboard = ClipboardSync(link: link)
    private let model = MenuModel()
    private let nowPlaying = NowPlaying()
    /// Tapa cerrada / Mac durmiendo: no hay nada sonando, quitar el reproductor del celular
    private var macAsleep = false
    private let volume = SystemVolume()
    private lazy var notifications = PhoneNotifications(link: link)
    private let proximity = Proximity()
    private lazy var hotspot = Hotspot(proximity: proximity)
    private let defaults = UserDefaults.standard
    private let mirror = Mirror()
    private let focus = FocusSync()
    private let messages = MessagesWindow()
    private var adbKeep: Timer?
    private lazy var files = FileTransfer(link: link)
    /// Último estado de No molestar que informó el celular (nil hasta que conecta)
    private var phoneDnd: Bool?
    private let autoHotspot = AutoHotspot()
    /// El hotspot actual lo encendió Puente solo (se apaga solo al llegar a casa)
    private var hotspotIsAuto = false
    /// El celular está en una red de confianza (solo vale mientras hay conexión con él)
    private var phoneAtHome = false
    private let mic = MicWatch()
    /// No molestar del celular lo puso Puente por una reunión (se quita al terminar)
    private var micSetDnd = false

    func applicationWillFinishLaunching(_ n: Notification) {
        // Enlaces tel: y sms: (Chrome, Opera, correos) → el celular
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(openURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func openURL(_ e: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = e.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let u = URL(string: s) else { return }
        let target = (s.split(separator: ":", maxSplits: 1).last.map(String.init) ?? "")
            .removingPercentEncoding?.components(separatedBy: "?").first?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) ?? ""
        switch u.scheme?.lowercased() {
        case "tel", "telprompt", "callto":
            guard link.isConnected else { Toast.show("Tu celular no está conectado", "No se pudo llamar a \(target)"); return }
            link.send(["t": "dial", "number": target])
            Toast.show("Llamando desde tu celular", target)
        case "sms", "smsto":
            openCompose(to: target)
        case "puente": // puente://pantalla, puente://mensajes (para Atajos o Spotlight)
            switch u.host?.lowercased() {
            case "pantalla": model.onMirror?()
            case "mensajes": openCompose(to: "")
            default: break
            }
        default: break
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        item.menu = buildMenu()
        files.attach(to: item)
        files.onStatus = { [weak self] s in self?.model.transfer = s }
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        clipboard.enabled = defaults.object(forKey: "clipboard") as? Bool ?? true
        model.clipboardOn = clipboard.enabled
        model.loginOn = LoginItem.isEnabled
        model.onClipboardToggle = { [weak self] on in
            self?.clipboard.enabled = on
            self?.defaults.set(on, forKey: "clipboard")
        }
        model.onLoginToggle = { on in on ? LoginItem.enable() : LoginItem.disable() }

        notifications.enabled = defaults.object(forKey: "notifications") as? Bool ?? true
        notifications.codesEnabled = defaults.object(forKey: "codes") as? Bool ?? true
        model.notifOn = notifications.enabled
        model.codesOn = notifications.codesEnabled
        model.onNotifToggle = { [weak self] on in self?.notifications.enabled = on; self?.defaults.set(on, forKey: "notifications") }
        model.onCodesToggle = { [weak self] on in self?.notifications.codesEnabled = on; self?.defaults.set(on, forKey: "codes") }
        notifications.onCode = { [weak self] code in self?.clipboard.copyCode(code) }
        notifications.start()

        proximity.lockEnabled = defaults.object(forKey: "lock") as? Bool ?? true
        proximity.sensitivity = Proximity.Sensitivity(rawValue: defaults.integer(forKey: "sensitivity")) ?? .medium
        if defaults.object(forKey: "sensitivity") == nil { proximity.sensitivity = .medium }
        model.lockOn = proximity.lockEnabled
        model.sensitivity = proximity.sensitivity
        model.hotspotReady = hotspot.hasCredentials
        model.onLockToggle = { [weak self] on in self?.proximity.lockEnabled = on; self?.defaults.set(on, forKey: "lock") }
        model.onSensitivity = { [weak self] v in self?.proximity.sensitivity = v; self?.defaults.set(v.rawValue, forKey: "sensitivity") }
        model.onHotspot = { [weak self] on in
            guard let self else { return }
            self.hotspotIsAuto = false
            if on { self.hotspot.connect() } else { self.hotspot.disconnect(); self.autoHotspot.userTurnedOff() }
        }
        proximity.onStatus = { [weak self] st in if self?.model.proximity != st { self?.model.proximity = st } }
        hotspot.onState = { [weak self] st in self?.model.hotspot = st }
        setupAutoHotspot()
        proximity.start()

        setupFeatures()
        clipboard.onActivity = { [weak self] a in self?.model.activity = a }
        clipboard.start()

        link.onState = { [weak self] s in
            guard let self else { return }
            switch s {
            case .searching:
                self.model.connected = false; self.model.battery = nil; self.model.ringing = false
                self.messages.model.connected = false; self.model.viaHotspot = false
                self.phoneDnd = nil
                self.phoneAtHome = false
            case .connected(let wifi):
                self.model.connected = true; self.model.wifi = wifi
                self.model.viaHotspot = self.link.netKind == .hotspot
                self.model.phoneName = self.defaults.string(forKey: "phoneName") ?? "Tu celular"
                // Celular recién conectado: mandarle lo que suena y el volumen
                if !self.macAsleep, let np = self.nowPlaying.snapshot { self.link.send(np) }
                self.link.send(["t": "vol", "v": self.volume.level])
                self.link.send(["t": "bleKey", "k": Secrets.bleKey.hex])
                self.link.send(["t": "photos", "on": self.model.photosOn])
                self.messages.model.connected = true
                if self.messages.isVisible { self.messages.model.refreshAll() }
            }
            self.refreshButton()
        }
        link.onMessage = { [weak self] m in
            guard let self else { return }
            switch m["t"] as? String {
            case "battery":
                self.model.battery = ((m["level"] as? Int) ?? 0, (m["charging"] as? Bool) ?? false)
                self.refreshButton()
            case "media":
                if let c = m["c"] as? String { self.nowPlaying.command(c, to: m["to"] as? Double) }
            case "setvol":
                if let v = m["v"] as? Int { self.volume.set(v) }
            case "hotspotCreds":
                self.hotspot.saveCredentials(ssid: m["ssid"] as? String ?? "", pass: m["pass"] as? String ?? "")
                self.model.hotspotReady = self.hotspot.hasCredentials
            case "ble":
                self.proximity.phoneBluetoothOn = m["on"] as? Bool ?? true
            case "notif", "call", "sms", "notifRemoved":
                self.notifications.handle(m)
            case "ringState":
                self.model.ringing = m["on"] as? Bool ?? false
            case "dnd":
                self.phoneDndChanged(m["on"] as? Bool ?? false)
            case "home":
                self.phoneHomeChanged(m["on"] as? Bool ?? false)
            case "photo":
                self.photoArrived(m)
            case "openOnMac":
                self.openFromPhone(m)
            case "contacts":
                let list = (m["list"] as? [[String]] ?? []).compactMap { $0.count == 2 ? (name: $0[0], number: $0[1]) : nil }
                self.messages.model.contacts = list.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            case "sims":
                self.messages.model.setSims(m["list"] as? [[String: Any]] ?? [], def: m["def"] as? Int ?? -1)
            case "smsSent":
                self.messages.model.sent(ok: m["ok"] as? Bool == true, err: m["err"] as? String)
            case "smsThreads":
                self.messages.model.setThreads(m["list"] as? [[String: Any]] ?? [])
            case "smsThread":
                self.messages.model.setThread(m)
            case "fileOut":
                self.files.receive(m)
            case "smsChanged":
                if self.messages.isVisible { self.messages.model.changed() }
            default:
                self.clipboard.handle(m)
            }
        }
        nowPlaying.onUpdate = { [weak self] np in
            guard let self, !self.macAsleep else { return }
            self.link.send(np)
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.macAsleep = true
            self.link.send(["t": "np", "none": true])
            Log.info("Mac a dormir: reproductor quitado del celular")
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.macAsleep = self.lidClosed
            if !self.lidClosed, let np = self.nowPlaying.snapshot, np["none"] as? Bool != true { self.link.send(np) }
        }
        // Tapa cerrada (aunque el Mac siga despierto descargando): desconectar Puente del celular
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkLid() }
        checkLid()
        volume.onChange = { [weak self] v in self?.link.send(["t": "vol", "v": v]) }
        volume.start()
        nowPlaying.start()

        refreshButton()
        link.start()
    }

    private var lidClosed = false

    // MARK: Funciones nuevas

    private func setupFeatures() {
        BrowserTab.track()
        model.photosOn = defaults.object(forKey: "photos") as? Bool ?? true
        model.dndOn = defaults.object(forKey: "dndSync") as? Bool ?? true
        model.onPhotosToggle = { [weak self] on in
            self?.defaults.set(on, forKey: "photos"); self?.link.send(["t": "photos", "on": on])
        }
        model.onDndToggle = { [weak self] on in self?.defaults.set(on, forKey: "dndSync") }
        model.onInstallShortcuts = { FocusSync.installShortcuts() }
        DispatchQueue.global().async { let ok = FocusSync.shortcutsInstalled; DispatchQueue.main.async { self.model.dndReady = ok } }

        mirror.onChange = { [weak self] on in
            guard let self else { return }
            self.model.mirroring = on
            // Sin cable, la pantalla usa adb por Wi‑Fi: mantenerla encendida mientras se mira y soltarla al cerrar
            self.adbKeep?.invalidate(); self.adbKeep = nil
            guard self.link.device == nil else { return }
            if on { self.adbKeep = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.link.keepAdb(true) } }
            else { self.link.keepAdb(false) }
        }
        model.onMirror = { [weak self] in
            guard let self else { return }
            self.link.withAdb { [weak self] serial in
                guard let self else { return }
                if let serial { self.mirror.open(serial: serial) }
                else { Toast.show("No se pudo abrir la pantalla", "La depuración inalámbrica no respondió") }
            }
        }
        link.askAdbOverBluetooth = { [weak self] in
            guard let self, self.proximity.status.seen else { return false }
            Log.info("pidiendo depuración inalámbrica por Bluetooth")
            self.proximity.send(command: 3) { ok in Log.info("bluetooth: depuración inalámbrica \(ok ? "pedida" : "sin respuesta")") }
            return true
        }
        model.onRing = { [weak self] in
            guard let self else { return }
            self.model.ringing.toggle()
            self.link.send(["t": self.model.ringing ? "ring" : "ringStop"])
        }
        model.onSendTab = { [weak self] in
            guard let self else { return }
            let r = BrowserTab.current()
            if let url = r.url {
                self.link.send(["t": "openUrl", "url": url])
                self.model.tabError = nil
                Toast.show("Abierto en tu celular", url)
            } else {
                self.model.tabError = r.error
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.model.tabError = nil }
            }
        }
        model.onCompose = { [weak self] in self?.openCompose(to: "") }
        model.onSendFile = { [weak self] in
            self?.item.menu?.cancelTracking()
            DispatchQueue.main.async { self?.files.pick() }
        }
        messages.model.request = { [weak self] m in self?.link.send(m) }
        messages.model.connected = link.isConnected
        notifications.onOpenSms = { [weak self] from in self?.openCompose(to: from) }

        focus.onMacChange = { [weak self] on in
            guard let self, self.model.dndOn, self.link.isConnected, self.phoneDnd != on else { return }
            Log.info("concentración del Mac: \(on) → celular")
            self.phoneDnd = on
            self.link.send(["t": "dnd", "on": on])
        }
        focus.start()

        model.micDndOn = defaults.object(forKey: "micDnd") as? Bool ?? true
        model.onMicDndToggle = { [weak self] on in
            guard let self else { return }
            self.defaults.set(on, forKey: "micDnd")
            if !on && self.micSetDnd { self.micChanged(false) }
        }
        mic.onChange = { [weak self] on in self?.micChanged(on) }
        mic.start()

        // Ser la app para enlaces tel: y sms: (macOS puede pedir confirmación una vez)
        if !defaults.bool(forKey: "urlHandlers") {
            for scheme in ["tel", "sms"] {
                NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme) { err in
                    if let err { Log.info("enlaces \(scheme): \(err.localizedDescription)") }
                }
            }
            defaults.set(true, forKey: "urlHandlers")
        }
    }

    // MARK: Automatizaciones

    private func setupAutoHotspot() {
        model.autoHotspotOn = defaults.object(forKey: "autoHotspot") as? Bool ?? true
        model.onAutoHotspotToggle = { [weak self] on in self?.defaults.set(on, forKey: "autoHotspot") }
        autoHotspot.canConnect = { [weak self] in
            guard let self else { return false }
            return self.model.autoHotspotOn && self.hotspot.hasCredentials && self.proximity.status.seen
                && !self.phoneAtHome && !self.lidClosed && !AutoHotspot.screenLocked
                && self.hotspot.state != .connecting && self.hotspot.state != .connected
        }
        autoHotspot.connect = { [weak self] in
            guard let self else { return }
            self.hotspotIsAuto = true
            Toast.show("El Mac se quedó sin Wi‑Fi", "Conectando al hotspot de tu celular…")
            self.hotspot.connect()
        }
        autoHotspot.onLost = { [weak self] in self?.hotspot.markLost() }
        autoHotspot.start()
    }

    /// El celular llegó a una red de confianza: si el Mac va por el hotspot que Puente encendió solo, apagarlo.
    private func phoneHomeChanged(_ home: Bool) {
        phoneAtHome = home
        guard home, hotspotIsAuto, hotspot.state == .connected || link.netKind == .hotspot else { return }
        Log.info("hotspot automático: el celular llegó a casa, apagándolo")
        hotspotIsAuto = false
        hotspot.disconnect()
        Toast.show("Llegaste a casa", "Apagué el hotspot; el Mac vuelve a tu Wi‑Fi")
    }

    /// Reunión en el Mac → No molestar en el celular, y al terminar vuelve como estaba.
    private func micChanged(_ on: Bool) {
        if on {
            guard model.micDndOn, link.isConnected, phoneDnd == false else { return } // si ya estaba en No molestar, no se toca
            Log.info("reunión en el Mac: No molestar en el celular")
            micSetDnd = true; phoneDnd = true
            link.send(["t": "dnd", "on": true])
        } else if micSetDnd {
            guard link.isConnected else { return } // se quita al reconectar (phoneDndChanged)
            micSetDnd = false
            guard phoneDnd == true else { return }
            Log.info("reunión terminada: se quita No molestar del celular")
            phoneDnd = false
            link.send(["t": "dnd", "on": false])
        }
    }

    /// Finder › clic derecho › Servicios › "Enviar al celular"
    @objc func sendToPhone(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        files.send(urls)
    }

    /// Ventana de Mensajes; con un número, abre esa conversación (o una nueva).
    private func openCompose(to: String) {
        messages.show()
        if !to.isEmpty { messages.model.openNumber(to) }
    }

    private func phoneDndChanged(_ on: Bool) {
        if micSetDnd {
            if !on { micSetDnd = false }  // lo quitaste tú en el celular: ya no es asunto de Puente
            else if !mic.inUse {          // la reunión terminó mientras estaba desconectado
                micSetDnd = false; phoneDnd = false
                link.send(["t": "dnd", "on": false]); return
            }
        }
        let first = phoneDnd == nil
        let changed = phoneDnd != on
        phoneDnd = on
        // Al conectar solo se anota el estado; se sincroniza cuando cambia
        guard !first, changed, model.dndOn, model.dndReady, focus.macOn != on else { return }
        Log.info("no molestar del celular: \(on) → Mac")
        focus.setMac(on)
    }

    /// Fotos y capturas del celular: solo al portapapeles, sin guardar archivos en el Mac.
    private func photoArrived(_ m: [String: Any]) {
        guard let b64 = m["b64"] as? String, let data = Data(base64Encoded: b64) else { return }
        let shot = m["shot"] as? Bool ?? false
        let mime = m["mime"] as? String ?? "image/jpeg"
        clipboard.putImageData(data, mime: mime)
        let ext = mime == "image/png" ? "png" : mime == "image/heic" ? "heic" : "jpg"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("puente-\(UUID().uuidString).\(ext)")
        try? data.write(to: tmp)
        Toast.show(shot ? "Captura del celular" : "Foto del celular", "En el portapapeles, lista para pegar con ⌘V", image: tmp)
        try? FileManager.default.removeItem(at: tmp)
    }

    private func openFromPhone(_ m: [String: Any]) {
        if let s = m["url"] as? String, let u = URL(string: s), u.scheme?.hasPrefix("http") == true {
            NSWorkspace.shared.open(u)
        } else if let t = m["text"] as? String, !t.isEmpty {
            clipboard.handle(["t": "text", "d": t])
            Toast.show("Texto del celular copiado", t)
        }
    }

    private func checkLid() {
        let closed = Self.lidIsClosed()
        guard closed != lidClosed else { return }
        lidClosed = closed
        if closed {
            Log.info("tapa cerrada: Puente en pausa")
            macAsleep = true
            link.send(["t": "np", "none": true])
            // dar un momento a que el mensaje llegue antes de cortar
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.lidClosed else { return }
                self.link.paused = true
                self.mirror.close()
            }
        } else {
            Log.info("tapa abierta: Puente reanudado")
            macAsleep = false
            link.paused = false
        }
        refreshButton()
    }

    static func lidIsClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (v?.takeRetainedValue() as? Bool) ?? false
    }

    func applicationWillTerminate(_ n: Notification) { link.stop(); nowPlaying.stop() }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(hostedItem(DeviceCard(m: model)))
        menu.addItem(hostedItem(ActionsSection(m: model)))
        menu.addItem(.separator())
        menu.addItem(hostedItem(ClipboardSection(m: model)))
        menu.addItem(.separator())
        menu.addItem(hostedItem(NotificationsSection(m: model)))
        menu.addItem(.separator())
        menu.addItem(hostedItem(NearbySection(m: model)))
        menu.addItem(.separator())
        menu.addItem(hostedItem(SettingsSection(m: model)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Salir de Puente", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.now = Date()
        model.loginOn = LoginItem.isEnabled
        // Las vistas cambian de alto (p. ej. aparece la última copia): reajustar
        DispatchQueue.main.async {
            for mi in menu.items { if let v = mi.view { v.frame.size = v.fittingSize } }
        }
        for mi in menu.items { if let v = mi.view { v.frame.size = v.fittingSize } }
    }

    private func refreshButton() {
        guard let b = item.button else { return }
        b.image = StatusIcon.make(level: model.battery?.level, charging: model.battery?.charging ?? false,
                                  connected: model.connected)
        b.toolTip = model.connected
            ? "\(model.phoneName) · \(model.battery.map { "\($0.level) %" } ?? "conectado")"
            : lidClosed ? "Puente en pausa: tapa cerrada" : "Puente: buscando tu celular"
        b.title = ""
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// Arranque al iniciar sesión mediante un LaunchAgent (se reabre solo si se cierra inesperadamente).
enum LoginItem {
    static let label = "cl.hazlo.puente"
    static var plist: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plist) }

    static func enable() {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
        ]
        let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        FileManager.default.createFile(atPath: plist, contents: data)
    }

    static func disable() {
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(atPath: plist)
    }

    @discardableResult
    static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { Snapshot.run(CommandLine.arguments[i + 1]) }; exit(0)
}

// Una sola copia de Puente a la vez
let others = NSRunningApplication.runningApplications(withBundleIdentifier: "cl.hazlo.puente")
    .filter { $0.processIdentifier != getpid() }
if !others.isEmpty { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
