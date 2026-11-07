import Foundation

/// Registro en ~/Library/Logs/Puente.log (sin contenido del portapapeles, solo eventos).
enum Log {
    private static let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Puente.log")
    private static let q = DispatchQueue(label: "puente.log")
    static func info(_ s: String) {
        q.async {
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        }
    }
}
