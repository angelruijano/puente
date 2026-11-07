import AppKit
import UserNotifications

/// Notificaciones del celular como notificaciones nativas del Mac, con sus botones (p. ej. Contestar / Rechazar).
/// Descartar en el Mac también la descarta en el celular, y al revés.
final class PhoneNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let link: PhoneLink
    private let center = UNUserNotificationCenter.current()
    private var categories: [String: UNNotificationCategory] = [:]
    var enabled = true
    var codesEnabled = true
    /// Se llama con el código detectado (para copiarlo al portapapeles).
    var onCode: ((String) -> Void)?

    init(link: PhoneLink) {
        self.link = link
        super.init()
        center.delegate = self
    }

    var onOpenSms: ((String) -> Void)?

    func start() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { ok, err in
            Log.info("notificaciones: permiso \(ok ? "concedido" : "denegado")\(err.map { " (\($0.localizedDescription))" } ?? "")")
        }
    }

    // MARK: celular → Mac

    func handle(_ m: [String: Any]) {
        switch m["t"] as? String {
        case "notif": notif(m)
        case "call": call(m)
        case "sms": sms(m)
        case "notifRemoved":
            if let key = m["key"] as? String { center.removeDeliveredNotifications(withIdentifiers: [key]) }
        default: break
        }
    }

    private func notif(_ m: [String: Any]) {
        let app = m["app"] as? String ?? ""
        let title = m["title"] as? String ?? ""
        let text = m["text"] as? String ?? ""
        let code = codesEnabled ? OTP.find(in: title + "\n" + text) : nil
        if let code { onCode?(code) }
        guard enabled else { return }

        let c = UNMutableNotificationContent()
        c.title = title.isEmpty ? app : title
        if !title.isEmpty, title != app { c.subtitle = app }
        c.body = text
        if let code { c.subtitle = "Código \(OTP.pretty(code)) copiado · \(app)" }
        c.threadIdentifier = m["pkg"] as? String ?? app
        c.sound = .default
        c.userInfo = ["key": m["key"] ?? "", "kind": "notif"]
        attach(c, m["image"] as? String ?? m["icon"] as? String)
        deliver(c, id: m["key"] as? String, actions: m["actions"] as? [String] ?? [], inputs: m["inputs"] as? [Int] ?? [])
    }

    private func call(_ m: [String: Any]) {
        guard enabled else { return }
        let who = (m["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Número desconocido"
        let c = UNMutableNotificationContent()
        c.title = who
        c.subtitle = "Llamada entrante en tu celular"
        c.body = m["text"] as? String ?? ""
        c.sound = .default
        c.interruptionLevel = .timeSensitive
        c.userInfo = ["key": m["key"] ?? "", "kind": "call"]
        attach(c, m["image"] as? String ?? m["icon"] as? String)
        deliver(c, id: m["key"] as? String, actions: m["actions"] as? [String] ?? [])
    }

    private func sms(_ m: [String: Any]) {
        let body = m["body"] as? String ?? ""
        let from = m["from"] as? String ?? ""
        let name = (m["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? from
        let code = codesEnabled ? OTP.find(in: body) : nil
        if let code { onCode?(code) }
        guard enabled || code != nil else { return }

        let c = UNMutableNotificationContent()
        c.title = name
        c.subtitle = code.map { "Código \(OTP.pretty($0)) copiado · pega con ⌘V" } ?? "Mensaje"
        c.body = body
        c.threadIdentifier = "sms:" + from
        c.sound = .default
        c.userInfo = ["key": m["key"] ?? "", "kind": "sms", "from": from]
        attach(c, m["icon"] as? String)
        // Varios SMS pueden compartir notificación: identificador propio para que no se pisen
        deliver(c, id: (m["key"] as? String ?? "sms") + ":" + String(body.hashValue),
                actions: m["actions"] as? [String] ?? [], inputs: m["inputs"] as? [Int] ?? [])
    }

    private func attach(_ c: UNMutableNotificationContent, _ b64: String?) {
        guard let b64, !b64.isEmpty, let data = Data(base64Encoded: b64) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("puente-\(UUID().uuidString).png")
        guard (try? data.write(to: url)) != nil,
              let a = try? UNNotificationAttachment(identifier: "img", url: url, options: nil) else { return }
        c.attachments = [a]
    }

    /// Las acciones dependen de cada notificación: se registra una categoría por combinación de botones.
    private func deliver(_ c: UNMutableNotificationContent, id: String?, actions: [String], inputs: [Int] = []) {
        let catId = "a:" + actions.joined(separator: "|") + "#" + inputs.map(String.init).joined(separator: ",")
        var delay = 0.0
        if categories[catId] == nil {
            let acts = actions.enumerated().compactMap { i, t -> UNNotificationAction? in
                if t.isEmpty { return nil }
                if inputs.contains(i) {
                    // "Responder": cuadro de texto en la notificación del Mac
                    return UNTextInputNotificationAction(identifier: "a\(i)", title: t, options: [],
                                                         textInputButtonTitle: "Enviar", textInputPlaceholder: "Mensaje")
                }
                return UNNotificationAction(identifier: "a\(i)", title: t, options: [])
            }
            categories[catId] = UNNotificationCategory(identifier: catId, actions: acts, intentIdentifiers: [],
                                                       options: [.customDismissAction])
            center.setNotificationCategories(Set(categories.values))
            delay = 0.3 // dar tiempo a que macOS registre la categoría
        }
        c.categoryIdentifier = catId
        let req = UNNotificationRequest(identifier: id ?? UUID().uuidString, content: c, trigger: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.center.add(req) { err in if let err { Log.info("notificación: \(err.localizedDescription)") } }
        }
    }

    // MARK: Mac → celular

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = r.notification.request.content.userInfo
        let key = info["key"] as? String ?? ""
        let kind = info["kind"] as? String ?? ""
        let id = r.actionIdentifier
        let reply = (r as? UNTextInputNotificationResponse)?.userText
        let path = info["path"] as? String
        DispatchQueue.main.async {
            if kind == "puente" {
                if let path, id == UNNotificationDefaultActionIdentifier { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                return
            }
            if id.hasPrefix("a"), let i = Int(id.dropFirst()) {
                var m: [String: Any] = ["t": "notifAction", "key": key, "i": i]
                if let reply { m["text"] = reply }
                self.link.send(m)
            } else if id == UNNotificationDismissActionIdentifier || id == UNNotificationDefaultActionIdentifier {
                // Clic en un SMS: abrir la conversación en la ventana de Mensajes
                if kind == "sms", id == UNNotificationDefaultActionIdentifier, let from = info["from"] as? String, !from.isEmpty {
                    self.onOpenSms?(from)
                }
                // Vista o descartada en el Mac: quitarla del celular (las llamadas no)
                if kind != "call", !key.isEmpty { self.link.send(["t": "notifDismiss", "key": key]) }
            }
        }
        done()
    }
}

/// Detección de códigos de verificación (SMS o apps de bancos).
enum OTP {
    private static let keywords = try! NSRegularExpression(
        pattern: "c[oó]digo|code|clave|otp|verificaci[oó]n|verification|\\bpin\\b|contrase[nñ]a|password|token|passcode|seguridad|autenticaci[oó]n|login|ingres",
        options: [.caseInsensitive])
    private static let candidates = try! NSRegularExpression(
        pattern: "(?<![\\d$.,:/])(\\d{3}[- ]\\d{3}|\\d{4,8})(?![\\d]|[.,:/]\\d)")

    static func find(in text: String) -> String? {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let kw = keywords.firstMatch(in: text, range: full) else { return nil }
        let all = candidates.matches(in: text, range: full).filter { m in
            let s = ns.substring(with: m.range)
            // descartar años y montos tipo "1.500" (ya excluidos) y horas
            if s.count == 4, let y = Int(s), (1990...2100).contains(y) { return false }
            return true
        }
        guard !all.isEmpty else { return nil }
        // El candidato más cercano a la palabra clave
        let best = all.min { abs($0.range.location - kw.range.location) < abs($1.range.location - kw.range.location) }!
        return ns.substring(with: best.range).filter(\.isNumber)
    }

    static func pretty(_ c: String) -> String {
        c.count == 6 ? String(c.prefix(3)) + " " + String(c.suffix(3)) : c
    }
}
