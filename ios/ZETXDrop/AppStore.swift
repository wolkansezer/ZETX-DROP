import Foundation
import MultipeerConnectivity
import SwiftUI
import UIKit

@MainActor
final class AppStore: ObservableObject {
    // Settings
    @Published var deviceName: String { didSet { defaults.set(deviceName, forKey: "name") } }
    @Published var autoSave: Bool { didSet { defaults.set(autoSave, forKey: "autoSave") } }
    @Published var nearbyEnabled: Bool { didSet { defaults.set(nearbyEnabled, forKey: "nearby"); peers.setEnabled(nearbyEnabled) } }
    @Published var cloudURL: String { didSet { defaults.set(cloudURL, forKey: "cloudURL") } }
    @Published var cloudKeySet: Bool

    // PC connection
    enum PCState: Equatable { case searching, connected, notFound }
    @Published var pcState: PCState = .searching
    @Published var pc: PCInfo?
    @Published var foundPCs: [PCInfo] = []
    @Published var remote: [RemoteDevice] = []
    @Published var toolBanner: String?

    // Activity
    @Published var transfers: [TransferItem] = []
    @Published var inbox: [ReceivedItem] = []
    @Published var jobs: [MediaJob] = []
    @Published var toast: Toast?
    @Published var unseen = 0

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let ok: Bool
    }

    let peers: PeerService
    let clientID: String
    private let defaults = UserDefaults.standard
    private var eventsTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var handled = Set<String>()
    private var lastEvent = Date()
    var cloudKeys: [String: String] = [:]

    init() {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "clientID") {
            clientID = id
        } else {
            clientID = "c-ios-" + UUID().uuidString.prefix(12).lowercased()
            d.set(clientID, forKey: "clientID")
        }
        let name = d.string(forKey: "name") ?? AppStore.defaultName()
        deviceName = name
        autoSave = d.object(forKey: "autoSave") as? Bool ?? true
        nearbyEnabled = d.object(forKey: "nearby") as? Bool ?? true
        cloudURL = d.string(forKey: "cloudURL") ?? ""
        cloudKeySet = Keychain.get("cobaltKey") != nil
        peers = PeerService(name: name)
        peers.enabled = nearbyEnabled
        wirePeers()
        loadInbox()
        peers.start()
        Task { await connectBest() }
    }

    private static func defaultName() -> String {
        let n = UIDevice.current.name
        if n == "iPhone" || n.isEmpty {
            return "iPhone " + String(UUID().uuidString.prefix(3))
        }
        return n
    }

    var base: URL? {
        guard let pc else { return nil }
        return URL(string: "http://\(pc.host):\(PCInfo.port)")
    }

    func show(_ text: String, ok: Bool = true) {
        toast = Toast(text: text, ok: ok)
        let id = toast?.id
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if self.toast?.id == id { self.toast = nil }
        }
    }

    // MARK: Lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            peers.start()
            if pc != nil { startEvents() } else { Task { await connectBest() } }
        case .background:
            eventsTask?.cancel()
        default:
            break
        }
    }

    func rename(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        deviceName = n
        peers.rename(n)
        if pc != nil { startEvents() }
    }

    // MARK: PC discovery

    func connectBest() async {
        if let last = defaults.string(forKey: "lastPC"), let info = await LAN.probe(last) {
            connect(info)
            return
        }
        await rescan(autoConnect: true)
    }

    func rescan(autoConnect: Bool) async {
        if pc == nil { pcState = .searching }
        let list = await LAN.scan()
        foundPCs = list
        if autoConnect, pc == nil, let first = list.first {
            connect(first)
        } else if pc == nil {
            pcState = .notFound
            scheduleRescan()
        }
    }

    private func scheduleRescan() {
        scanTask?.cancel()
        scanTask = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, self.pc == nil, UIApplication.shared.applicationState == .active else { return }
            await self.rescan(autoConnect: true)
        }
    }

    func connectManual(_ host: String) async -> Bool {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
            .components(separatedBy: ":").first ?? ""
        guard !h.isEmpty, let info = await LAN.probe(h) else {
            show("\(h) adresinde ZETX DROP bulunamadı", ok: false)
            return false
        }
        connect(info)
        return true
    }

    func connect(_ info: PCInfo) {
        pc = info
        pcState = .connected
        defaults.set(info.host, forKey: "lastPC")
        if !foundPCs.contains(info) { foundPCs.append(info) }
        startEvents()
    }

    func disconnect() {
        eventsTask?.cancel()
        pc = nil
        remote = []
        pcState = .notFound
        defaults.removeObject(forKey: "lastPC")
    }

    // MARK: Server events (SSE)

    private func startEvents() {
        eventsTask?.cancel()
        guard let base else { return }
        let id = clientID, name = deviceName
        eventsTask = Task {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 45
            cfg.timeoutIntervalForResource = 60 * 60 * 24 * 7
            let session = URLSession(configuration: cfg)
            var failures = 0
            while !Task.isCancelled {
                var comps = URLComponents(url: base.appendingPathComponent("api/events"), resolvingAgainstBaseURL: false)!
                comps.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "name", value: name), URLQueryItem(name: "kind", value: "iphone")]
                do {
                    let (bytes, resp) = try await session.bytes(from: comps.url!)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw NetError.http(0) }
                    failures = 0
                    self.pcState = .connected
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if let ev = try? JSONDecoder().decode(ServerEvent.self, from: Data(json.utf8)) {
                            self.handle(ev)
                        }
                    }
                } catch {
                    if Task.isCancelled { break }
                }
                failures += 1
                if failures >= 3 {
                    // PC went away (closed or changed network): look for it again.
                    self.remote = []
                    if let pc = self.pc, await LAN.probe(pc.host) == nil {
                        self.pc = nil
                        self.pcState = .searching
                        await self.rescan(autoConnect: true)
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            session.invalidateAndCancel()
        }
    }

    private func handle(_ ev: ServerEvent) {
        switch ev.type {
        case "devices":
            remote = (ev.devices ?? []).filter { $0.id != clientID }
        case "incoming":
            if let t = ev.transfer { receiveFromPC(t) }
        case "job":
            updateJob(ev)
        case "tool":
            let pct = Int(ev.pct ?? 0)
            toolBanner = (pct < 0 || pct >= 100) ? nil : "PC'de \(ev.label ?? "motor") kuruluyor… %\(pct)"
        case "toast":
            if let m = ev.msg { show(m, ok: ev.level != "err") }
        default:
            break
        }
    }

    // MARK: Receiving

    private func receiveFromPC(_ t: IncomingTransfer) {
        guard !handled.contains(t.id), let base else { return }
        handled.insert(t.id)
        let key = "in-" + t.id
        transfers.insert(TransferItem(id: key, name: t.name, peer: t.from, size: t.size, direction: .incoming), at: 0)
        let relay = base.appendingPathComponent("api/relay/\(t.id)")
        Task {
            do {
                let tmp = try await Net.shared.download(relay, key: key) { p in
                    Task { @MainActor in self.setProgress(key, p) }
                }
                let dest = Files.unique(in: Files.inbox, name: t.name)
                try FileManager.default.moveItem(at: tmp, to: dest)
                var req = URLRequest(url: relay.appendingPathComponent("dismiss"))
                req.httpMethod = "POST"
                _ = try? await URLSession.shared.data(for: req)
                await self.finishReceive(dest, from: t.from, key: key)
            } catch {
                self.handled.remove(t.id)
                self.fail(key, error.localizedDescription)
            }
        }
    }

    private func wirePeers() {
        peers.onIncomingStart = { [weak self] key, name, from, progress in
            guard let self else { return }
            Task { @MainActor in
                self.transfers.insert(TransferItem(id: key, name: name, peer: from, size: progress.totalUnitCount, direction: .incoming), at: 0)
                while !progress.isFinished, !progress.isCancelled {
                    self.setProgress(key, progress.fractionCompleted)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }
        peers.onReceived = { [weak self] url, from, key in
            guard let self else { return }
            Task { @MainActor in await self.finishReceive(url, from: from, key: key) }
        }
        peers.onIncomingFailed = { [weak self] key, msg in
            guard let self else { return }
            Task { @MainActor in self.fail(key, msg) }
        }
    }

    func finishReceive(_ url: URL, from: String, key: String) async {
        let name = url.lastPathComponent
        var saved = false
        var detail = "Dosyalar → ZETX DROP → Gelenler"
        if autoSave && FileKind.isMedia(name) {
            do {
                try await PhotoSaver.save(url)
                saved = true
                detail = "Galeriye kaydedildi"
            } catch {
                detail = "Galeriye kaydedilemedi: \(error.localizedDescription)"
            }
        }
        let item = ReceivedItem(url: url, name: name, size: Files.size(url), from: from, date: Date(), savedToPhotos: saved)
        inbox.insert(item, at: 0)
        unseen += 1
        if let i = transfers.firstIndex(where: { $0.id == key }) {
            transfers[i].progress = 1
            transfers[i].state = .done
            transfers[i].detail = detail
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        show(saved ? "📸 \(name) galeriye kaydedildi" : "📥 \(name) alındı", ok: true)
    }

    func saveToPhotos(_ item: ReceivedItem) async {
        do {
            try await PhotoSaver.save(item.url)
            if let i = inbox.firstIndex(where: { $0.id == item.id }) { inbox[i].savedToPhotos = true }
            show("📸 Galeriye kaydedildi")
        } catch {
            show(error.localizedDescription, ok: false)
        }
    }

    func delete(_ item: ReceivedItem) {
        try? FileManager.default.removeItem(at: item.url)
        inbox.removeAll { $0.id == item.id }
    }

    private func loadInbox() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: Files.inbox, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        inbox = urls.map { u in
            let date = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            return ReceivedItem(url: u, name: u.lastPathComponent, size: Files.size(u), from: "—", date: date, savedToPhotos: false)
        }.sorted { $0.date > $1.date }
    }

    // MARK: Sending

    enum Target: Hashable {
        case pc(id: String, name: String)
        case nearby(MCPeerID)

        var name: String {
            switch self {
            case .pc(_, let n): return n
            case .nearby(let p): return p.displayName
            }
        }
    }

    /// ASCII-only so file names with Turkish characters survive HTTP headers.
    static let headerSafe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    func send(_ urls: [URL], to target: Target) {
        Task {
            for url in urls { await sendOne(url, to: target) }
        }
    }

    private func sendOne(_ url: URL, to target: Target) async {
        let key = "out-" + UUID().uuidString
        let name = url.lastPathComponent
        let size = Files.size(url)
        transfers.insert(TransferItem(id: key, name: name, peer: target.name, size: size, direction: .outgoing), at: 0)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            switch target {
            case .nearby(let peer):
                try await peers.send(url, to: peer) { p in
                    Task { @MainActor in self.setProgress(key, p) }
                }
            case .pc(let id, _):
                guard let base else { throw NetError.server("Bilgisayar bağlı değil") }
                var comps = URLComponents(url: base.appendingPathComponent("api/send"), resolvingAgainstBaseURL: false)!
                comps.queryItems = [URLQueryItem(name: "to", value: id), URLQueryItem(name: "from", value: clientID)]
                var req = URLRequest(url: comps.url!)
                req.httpMethod = "POST"
                req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                req.setValue(name.addingPercentEncoding(withAllowedCharacters: Self.headerSafe) ?? "dosya", forHTTPHeaderField: "X-File-Name")
                req.setValue(deviceName.addingPercentEncoding(withAllowedCharacters: Self.headerSafe) ?? "iPhone", forHTTPHeaderField: "X-From-Name")
                let (data, status) = try await Net.shared.upload(req, file: url, key: key) { p in
                    Task { @MainActor in self.setProgress(key, p) }
                }
                if status != 200 {
                    let msg = (try? JSONDecoder().decode(MediaInfo.self, from: data))?.error
                    throw NetError.server(msg ?? "Hata \(status)")
                }
            }
            if let i = transfers.firstIndex(where: { $0.id == key }) {
                let secs = max(Date().timeIntervalSince(transfers[i].startedAt), 0.01)
                transfers[i].progress = 1
                transfers[i].state = .done
                transfers[i].detail = "Gönderildi · ort. \(formatSize(Int64(Double(size) / secs)))/sn"
            }
        } catch {
            fail(key, error.localizedDescription)
        }
    }

    func cancel(_ item: TransferItem) {
        Net.shared.cancel(item.id)
    }

    private func setProgress(_ key: String, _ p: Double) {
        guard let i = transfers.firstIndex(where: { $0.id == key }), transfers[i].state == .running else { return }
        transfers[i].progress = p
        let secs = Date().timeIntervalSince(transfers[i].startedAt)
        if secs > 0.5, transfers[i].size > 0 {
            let speed = Double(transfers[i].size) * p / secs
            transfers[i].detail = "\(formatSize(Int64(Double(transfers[i].size) * p))) / \(formatSize(transfers[i].size)) · \(formatSize(Int64(speed)))/sn"
        }
    }

    private func fail(_ key: String, _ msg: String) {
        if let i = transfers.firstIndex(where: { $0.id == key }) {
            transfers[i].state = .failed(msg)
        }
    }

    // MARK: Media downloader (runs on the PC)

    func mediaInfo(_ link: String) async throws -> MediaInfo {
        guard let base else { throw NetError.server("Medya indirmek için bilgisayardaki ZETX DROP açık olmalı") }
        var req = URLRequest(url: base.appendingPathComponent("api/media/info"))
        req.httpMethod = "POST"
        req.timeoutInterval = 130
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["url": link, "cookies": ""])
        let (data, _) = try await URLSession.shared.data(for: req)
        let info = try JSONDecoder().decode(MediaInfo.self, from: data)
        if info.ok != true { throw NetError.server(info.error ?? "Analiz başarısız") }
        return info
    }

    func startMedia(link: String, mode: String, height: Int, bitrate: Int, compat: Bool, target: String, title: String, label: String) async {
        guard let base else { return }
        var req = URLRequest(url: base.appendingPathComponent("api/media/download"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["url": link, "mode": mode, "height": height, "bitrate": bitrate, "compat": compat, "cookies": "", "target": target, "from": clientID]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard obj?["ok"] as? Bool == true, let id = obj?["job"] as? String else {
                throw NetError.server(obj?["error"] as? String ?? "Başlatılamadı")
            }
            jobs.insert(MediaJob(id: id, title: title, label: label), at: 0)
        } catch {
            show(error.localizedDescription, ok: false)
        }
    }

    func cancelJob(_ job: MediaJob) {
        if job.id.hasPrefix("cl-") {
            if let i = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[i].state = "error"
                jobs[i].message = "✗ İptal edildi"
            }
            if let k = cloudKeys[job.id] { Net.shared.cancel(k) }
            return
        }
        guard let base else { return }
        var comps = URLComponents(url: base.appendingPathComponent("api/media/cancel"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "id", value: job.id)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        Task { _ = try? await URLSession.shared.data(for: req) }
    }

    private func updateJob(_ ev: ServerEvent) {
        guard let id = ev.id else { return }
        if jobs.firstIndex(where: { $0.id == id }) == nil {
            jobs.insert(MediaJob(id: id, title: ev.url ?? "Medya", label: ev.mode ?? ""), at: 0)
        }
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].state = ev.state ?? jobs[i].state
        switch ev.state {
        case "dl":
            jobs[i].pct = ev.pct ?? 0
            var parts = [String(format: "%%%.0f", ev.pct ?? 0)]
            if let s = ev.speed, !s.isEmpty { parts.append(s) }
            if let e = ev.eta, !e.isEmpty, e != "NA" { parts.append("\(e) kaldı") }
            if let m = ev.msg, m != "İndiriliyor" { parts.append(m) }
            jobs[i].message = parts.joined(separator: " · ")
        case "done":
            jobs[i].pct = 100
            jobs[i].message = "✓ Tamamlandı"
        case "error":
            jobs[i].message = "✗ " + (ev.msg ?? "Hata")
        default:
            jobs[i].message = ev.msg ?? jobs[i].message
            if ev.state == "post" { jobs[i].pct = 100 }
        }
    }
}
