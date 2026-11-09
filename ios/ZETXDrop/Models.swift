import Foundation
import UniformTypeIdentifiers

struct PCInfo: Decodable, Identifiable, Hashable {
    static let port = 8765
    let app: String?
    let name: String
    let version: String?
    var host: String = ""
    var id: String { host }

    enum CodingKeys: String, CodingKey { case app, name, version }
}

struct RemoteDevice: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let kind: String
    let ip: String?

    var symbol: String {
        switch kind {
        case "iphone", "android": return "iphone"
        case "ipad", "tablet": return "ipad"
        case "host": return "desktopcomputer"
        case "peer": return "pc"
        default: return "laptopcomputer"
        }
    }

    var kindLabel: String {
        switch kind {
        case "host": return "Bilgisayar"
        case "peer": return "Bilgisayar"
        case "iphone": return "iPhone"
        case "ipad": return "iPad"
        case "android": return "Android"
        case "tablet": return "Tablet"
        default: return "Cihaz"
        }
    }
}

struct IncomingTransfer: Decodable, Hashable {
    let id: String
    let name: String
    let size: Int64
    let from: String
}

struct ServerEvent: Decodable {
    let type: String
    let devices: [RemoteDevice]?
    let transfer: IncomingTransfer?
    let id: String?
    let state: String?
    let pct: Double?
    let speed: String?
    let eta: String?
    let msg: String?
    let url: String?
    let mode: String?
    let label: String?
    let level: String?
}

enum TransferDirection { case outgoing, incoming }

struct TransferItem: Identifiable {
    let id: String
    let name: String
    let peer: String
    let size: Int64
    let direction: TransferDirection
    var progress: Double = 0
    var state: State = .running
    var startedAt = Date()
    var detail = ""

    enum State: Equatable { case running, done, failed(String) }
}

struct ReceivedItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let size: Int64
    let from: String
    let date: Date
    var savedToPhotos: Bool
}

struct MediaInfo: Decodable {
    let ok: Bool?
    let error: String?
    let title: String?
    let thumbnail: String?
    let duration: Double?
    let uploader: String?
    let site: String?
    let heights: [Int]?
    let hasVideo: Bool?
    let imageOnly: Bool?
    let note: String?
}

struct MediaJob: Identifiable {
    let id: String
    var title: String
    var label: String
    var pct: Double = 0
    var state = "prep"
    var message = "Hazırlanıyor…"
}

enum FileKind {
    static func type(_ name: String) -> UTType? {
        UTType(filenameExtension: (name as NSString).pathExtension.lowercased())
    }

    static func isImage(_ name: String) -> Bool { type(name)?.conforms(to: .image) ?? false }
    static func isVideo(_ name: String) -> Bool { type(name)?.conforms(to: .movie) ?? false }
    static func isMedia(_ name: String) -> Bool { isImage(name) || isVideo(name) }
    static func isAudio(_ name: String) -> Bool { type(name)?.conforms(to: .audio) ?? false }

    static func symbol(_ name: String) -> String {
        if isImage(name) { return "photo" }
        if isVideo(name) { return "film" }
        if isAudio(name) { return "music.note" }
        return "doc"
    }
}

enum Files {
    static var inbox: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Gelenler", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func sanitize(_ name: String) -> String {
        var n = (name as NSString).lastPathComponent
        for c in ["/", "\\", ":", "\0"] { n = n.replacingOccurrences(of: c, with: "_") }
        n = n.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty || n == "." || n == ".." ? "dosya" : n
    }

    static func unique(in dir: URL, name: String) -> URL {
        let clean = sanitize(name)
        var url = dir.appendingPathComponent(clean)
        let ext = (clean as NSString).pathExtension
        let base = (clean as NSString).deletingPathExtension
        var i = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)")
            i += 1
        }
        return url
    }

    static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    /// Copies a picked file into our temp area so it stays readable while sending.
    static func stage(_ src: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("send-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(sanitize(src.lastPathComponent))
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }
}
