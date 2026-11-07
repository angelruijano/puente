import AppKit
import SwiftUI

// MARK: - Mensajes del celular en el Mac (SMS por las SIMs del celular)

struct SmsThread: Identifiable, Equatable {
    let id: Int64
    let addr: String
    let snippet: String
    let date: Date
    let out: Bool
    let sub: Int
    let unread: Int
}

struct SmsMsg: Identifiable, Equatable {
    let id: Int64
    let body: String
    let date: Date
    let out: Bool
    let sub: Int
    var state: String  // ok, sending, failed
}

final class MessagesModel: ObservableObject {
    @Published var threads: [SmsThread] = []
    @Published var loaded = false
    @Published var messages: [SmsMsg] = []
    @Published var selected: Int64?
    @Published var composingNew = false
    @Published var newTo = ""
    @Published var draft = ""
    @Published var search = ""
    @Published var error: String?
    @Published var connected = false
    @Published var contacts: [(name: String, number: String)] = [] { didSet { indexContacts() } }
    @Published var sims: [(id: Int, label: String, short: String)] = []
    @Published var sim: Int = UserDefaults.standard.object(forKey: "smsSim") as? Int ?? -1 {
        didSet { UserDefaults.standard.set(sim, forKey: "smsSim") }
    }

    /// Manda un mensaje al celular.
    var request: (([String: Any]) -> Void)?
    private var byDigits: [String: String] = [:]
    private var pendingNumber: String?
    private var localId: Int64 = -1

    // MARK: Datos del celular

    func setThreads(_ list: [[String: Any]]) {
        threads = list.compactMap { d in
            guard let id = (d["id"] as? NSNumber)?.int64Value else { return nil }
            return SmsThread(id: id, addr: d["addr"] as? String ?? "", snippet: d["snippet"] as? String ?? "",
                             date: Self.date(d["date"]), out: d["out"] as? Bool ?? false,
                             sub: d["sub"] as? Int ?? -1, unread: d["unread"] as? Int ?? 0)
        }
        loaded = true
        // Conversación nueva recién enviada: saltar a ella apenas aparece
        if let n = pendingNumber, let t = threads.first(where: { Self.same($0.addr, n) }) {
            pendingNumber = nil
            open(t.id)
        }
    }

    func setThread(_ m: [String: Any]) {
        guard let id = (m["id"] as? NSNumber)?.int64Value, id == selected else { return }
        let list: [SmsMsg] = (m["msgs"] as? [[String: Any]] ?? []).compactMap { d in
            guard let mid = (d["id"] as? NSNumber)?.int64Value else { return nil }
            return SmsMsg(id: mid, body: d["body"] as? String ?? "", date: Self.date(d["date"]), out: d["out"] as? Bool ?? false,
                          sub: d["sub"] as? Int ?? -1, state: d["state"] as? String ?? "ok")
        }
        // Lo que se está enviando y el celular aún no guarda, sigue visible al final
        let pending = messages.filter { p in
            p.id < 0 && !list.contains { $0.out && $0.body == p.body && abs($0.date.timeIntervalSince(p.date)) < 300 }
        }
        messages = list + pending
    }

    func setSims(_ list: [[String: Any]], def: Int) {
        sims = list.compactMap { d in
            guard let id = d["id"] as? Int else { return nil }
            let carrier = (d["carrier"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let name = (d["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let title = (carrier.isEmpty ? name : carrier).capitalized
            let slot = d["slot"] as? Int ?? 0
            return (id, "SIM \(slot) · \(title.isEmpty ? "Sin nombre" : title)", title.isEmpty ? "SIM \(slot)" : title)
        }
        if !sims.contains(where: { $0.id == sim }) { sim = sims.contains(where: { $0.id == def }) ? def : sims.first?.id ?? -1 }
    }

    func changed() {
        request?(["t": "smsThreads"])
        if let s = selected { request?(["t": "smsThread", "id": s]) }
    }

    func sent(ok: Bool, err: String?) {
        if ok { error = nil; return }
        error = "No se pudo enviar: \(err ?? "error desconocido")"
        if let i = messages.lastIndex(where: { $0.id < 0 && $0.state == "sending" }) { messages[i].state = "failed" }
    }

    // MARK: Acciones

    func refreshAll() {
        request?(["t": "smsThreads"])
        request?(["t": "contacts"])
        request?(["t": "sims"])
        if let s = selected { request?(["t": "smsThread", "id": s]) }
    }

    func open(_ id: Int64) {
        composingNew = false
        error = nil
        if selected != id { messages = [] }
        selected = id
        request?(["t": "smsThread", "id": id])
    }

    func startNew(to: String = "") {
        composingNew = true
        selected = nil
        messages = []
        newTo = to
        error = nil
    }

    /// Abrir desde un enlace sms: o desde una notificación: la conversación existente o una nueva.
    func openNumber(_ number: String) {
        if let t = threads.first(where: { Self.same($0.addr, number) }) { open(t.id) }
        else { startNew(to: number) }
    }

    var currentThread: SmsThread? { threads.first { $0.id == selected } }

    var recipient: String? {
        if composingNew {
            if let c = contacts.first(where: { $0.name == newTo }) { return c.number }
            return newTo.filter { $0.isNumber || $0 == "+" }.count >= 3 ? newTo : nil
        }
        return currentThread?.addr
    }

    var canSend: Bool {
        connected && recipient != nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() {
        guard canSend, let to = recipient else { return }
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        error = nil
        var msg: [String: Any] = ["t": "smsSend", "to": to, "body": body]
        if sim >= 0 { msg["sub"] = sim }
        request?(msg)
        messages.append(SmsMsg(id: localId, body: body, date: Date(), out: true, sub: sim, state: "sending"))
        localId -= 1
        if composingNew {
            if let t = threads.first(where: { Self.same($0.addr, to) }) { open(t.id); messages.append(SmsMsg(id: localId, body: body, date: Date(), out: true, sub: sim, state: "sending")); localId -= 1 }
            else { pendingNumber = to }
        }
    }

    // MARK: Nombres

    func name(for addr: String) -> String {
        if let n = byDigits[Self.key(addr)] { return n }
        return addr.isEmpty ? "Desconocido" : addr
    }

    var filtered: [SmsThread] {
        let q = Self.fold(search.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return threads }
        return threads.filter { Self.fold(name(for: $0.addr)).contains(q) || $0.addr.contains(q) || Self.fold($0.snippet).contains(q) }
    }

    var suggestions: [(name: String, number: String)] {
        let q = Self.fold(newTo.trimmingCharacters(in: .whitespaces))
        guard q.count >= 2, !q.allSatisfy({ $0.isNumber || $0 == "+" || $0 == " " }),
              !contacts.contains(where: { $0.name == newTo }) else { return [] }
        return Array(contacts.filter { Self.fold($0.name).contains(q) }.prefix(6))
    }

    func simShort(_ id: Int) -> String? { sims.count > 1 ? sims.first { $0.id == id }?.short : nil }

    private func indexContacts() {
        var d: [String: String] = [:]
        for c in contacts { let k = Self.key(c.number); if !k.isEmpty, d[k] == nil { d[k] = c.name } }
        byDigits = d
    }

    // MARK: Utilidades

    static func key(_ s: String) -> String { String(s.filter(\.isNumber).suffix(8)) }
    static func same(_ a: String, _ b: String) -> Bool { let x = key(a); return !x.isEmpty && x == key(b) }
    static func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }
    static func date(_ v: Any?) -> Date { Date(timeIntervalSince1970: ((v as? NSNumber)?.doubleValue ?? 0) / 1000) }
}

// MARK: - Vista

struct MessagesView: View {
    @ObservedObject var m: MessagesModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(m: m).frame(width: 280)
            Divider()
            Group {
                if m.composingNew || m.selected != nil { Conversation(m: m) }
                else { Placeholder(m: m) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 460)
    }
}

private struct Sidebar: View {
    @ObservedObject var m: MessagesModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Buscar", text: $m.search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
                Button { m.startNew() } label: { Image(systemName: "square.and.pencil").font(.system(size: 15)) }
                    .buttonStyle(.borderless)
                    .help("Mensaje nuevo")
            }
            .padding(10)
            ScrollView {
                LazyVStack(spacing: 2) {
                    if m.composingNew {
                        Row(title: m.newTo.isEmpty ? "Mensaje nuevo" : m.newTo, snippet: "", date: nil, unread: 0, selected: true)
                    }
                    ForEach(m.filtered) { t in
                        Button { m.open(t.id) } label: {
                            Row(title: m.name(for: t.addr), snippet: (t.out ? "Tú: " : "") + t.snippet,
                                date: t.date, unread: t.unread, selected: t.id == m.selected && !m.composingNew)
                        }
                        .buttonStyle(.plain)
                    }
                    if m.loaded && m.filtered.isEmpty && !m.composingNew {
                        Text(m.search.isEmpty ? "Sin mensajes" : "Sin resultados")
                            .foregroundStyle(.secondary).padding(.top, 30)
                    }
                    if !m.loaded {
                        ProgressView().controlSize(.small).padding(.top, 30)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .background(.ultraThinMaterial)
    }
}

private struct Row: View {
    let title: String
    let snippet: String
    let date: Date?
    let unread: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(unread > 0 ? Color.accentColor : .clear).frame(width: 7, height: 7)
            Avatar(name: title, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if let date { Text(Stamp.short(date)).font(.system(size: 11)).foregroundStyle(selected ? .white.opacity(0.85) : .secondary) }
                }
                Text(snippet.isEmpty ? " " : snippet)
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 7).padding(.trailing, 8).padding(.leading, 2)
        .foregroundStyle(selected ? .white : .primary)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor : .clear))
        .contentShape(Rectangle())
    }
}

private struct Avatar: View {
    let name: String
    let size: CGFloat

    var body: some View {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first(where: \.isLetter) }.map { String($0).uppercased() }.joined()
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(white: 0.66), Color(white: 0.52)], startPoint: .top, endPoint: .bottom))
            if letters.isEmpty { Image(systemName: "person.fill").font(.system(size: size * 0.45)).foregroundStyle(.white) }
            else { Text(letters).font(.system(size: size * 0.4, weight: .medium)).foregroundStyle(.white) }
        }
        .frame(width: size, height: size)
    }
}

private struct Conversation: View {
    @ObservedObject var m: MessagesModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(m.messages.enumerated()), id: \.element.id) { i, msg in
                            if i == 0 || msg.date.timeIntervalSince(m.messages[i - 1].date) > 3600 {
                                Text(Stamp.long(msg.date)).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .padding(.top, 12).padding(.bottom, 4)
                            }
                            Bubble(msg: msg, sim: m.simShort(msg.sub),
                                   showSim: msg.out && m.messages[..<i].last(where: \.out)?.sub != msg.sub)
                                .id(msg.id)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
                .onChange(of: m.messages) { _ in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("end", anchor: .bottom) } }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            if let e = m.error {
                Text(e).font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 14).padding(.top, 6)
            }
            composer
        }
        .onAppear { focused = !m.composingNew }
    }

    @ViewBuilder private var header: some View {
        if m.composingNew {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Para:").foregroundStyle(.secondary)
                    TextField("Nombre o número", text: $m.newTo).textFieldStyle(.plain)
                        .onSubmit { focused = true }
                }
                ForEach(m.suggestions, id: \.number) { c in
                    Button { m.newTo = c.name; focused = true } label: {
                        HStack { Avatar(name: c.name, size: 22); Text(c.name); Spacer(); Text(c.number).foregroundStyle(.secondary) }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        } else if let t = m.currentThread {
            VStack(spacing: 3) {
                Avatar(name: m.name(for: t.addr), size: 34)
                Text(m.name(for: t.addr)).font(.system(size: 12, weight: .semibold))
                if m.name(for: t.addr) != t.addr { Text(t.addr).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if m.sims.count > 1 {
                Picker("", selection: $m.sim) {
                    ForEach(m.sims, id: \.id) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                .help("SIM por la que sale el mensaje")
            }
            HStack(alignment: .bottom) {
                TextField(m.connected ? "Mensaje de texto" : "Celular desconectado", text: $m.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit { m.send() }
                    .disabled(!m.connected)
                Button { m.send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                        .foregroundStyle(m.canSend ? Color.green : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!m.canSend)
            }
            .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.35)))
        }
        .padding(12)
    }
}

private struct Bubble: View {
    let msg: SmsMsg
    let sim: String?
    let showSim: Bool

    var body: some View {
        VStack(alignment: msg.out ? .trailing : .leading, spacing: 2) {
            if showSim, let sim { Text("SMS · \(sim)").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 4) }
            HStack {
                if msg.out { Spacer(minLength: 80) }
                Text(msg.body)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .foregroundStyle(msg.out ? .white : .primary)
                    .background(RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(msg.out ? Color(red: 0.2, green: 0.78, blue: 0.35) : Color.primary.opacity(0.1)))
                    .opacity(msg.state == "sending" ? 0.6 : 1)
                    .help(Stamp.long(msg.date))
                if !msg.out { Spacer(minLength: 80) }
            }
            if msg.state == "failed" {
                Label("No enviado", systemImage: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(.red)
            } else if msg.state == "sending" {
                Text("Enviando…").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: msg.out ? .trailing : .leading)
    }
}

private struct Placeholder: View {
    @ObservedObject var m: MessagesModel
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "message").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(m.connected ? "Elige una conversación" : "Tu celular no está conectado").foregroundStyle(.secondary)
            Button("Mensaje nuevo") { m.startNew() }.disabled(!m.connected)
        }
    }
}

enum Stamp {
    private static func fmt(_ f: String) -> DateFormatter {
        let d = DateFormatter(); d.locale = Locale(identifier: "es_CL"); d.setLocalizedDateFormatFromTemplate(f); return d
    }
    private static let time = fmt("HH:mm")
    private static let weekday = fmt("EEEE")
    private static let day = fmt("d MMM")
    private static let dayYear = fmt("d MMM y")

    static func short(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return time.string(from: d) }
        if cal.isDateInYesterday(d) { return "Ayer" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 { return weekday.string(from: d).capitalized }
        return (cal.isDate(d, equalTo: Date(), toGranularity: .year) ? day : dayYear).string(from: d)
    }

    static func long(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Hoy " + time.string(from: d) }
        if cal.isDateInYesterday(d) { return "Ayer " + time.string(from: d) }
        return short(d) + " " + time.string(from: d)
    }
}

// MARK: - Ventana

final class MessagesWindow: NSObject, NSWindowDelegate {
    let model = MessagesModel()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Mensajes"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: MessagesView(m: model).padding(.top, 1))
            w.setFrameAutosaveName("PuenteMensajes")
            if !w.setFrameUsingName("PuenteMensajes") { w.center() }
            w.delegate = self
            window = w
        }
        model.refreshAll()
        NSApp.setActivationPolicy(.regular)  // con ventana abierta: en el Dock y ⌘Tab, como una app normal
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible == true }

    func windowWillClose(_ notification: Notification) {
        model.error = nil
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}
