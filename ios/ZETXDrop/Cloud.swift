import Foundation
import Security
import SwiftUI

/// The API key lives in the iOS Keychain, never in plain settings.
enum Keychain {
    private static let service = "com.zetx.drop"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Response of a cobalt API instance (POST /).
struct CobaltResponse: Decodable {
    struct Item: Decodable {
        let type: String?
        let url: String
        let thumb: String?
    }

    struct Failure: Decodable {
        struct Context: Decodable {
            let service: String?
            let limit: Double?
        }
        let code: String
        let context: Context?
    }

    let status: String
    let url: String?
    let filename: String?
    let picker: [Item]?
    let audio: String?
    let audioFilename: String?
    let error: Failure?
}

enum CobaltError {
    static func message(_ f: CobaltResponse.Failure?) -> String {
        guard let f else { return "Sunucu bilinmeyen bir hata döndürdü" }
        let c = f.code
        let svc = f.context?.service.map { " (\($0))" } ?? ""
        switch true {
        case c.contains("auth.key"), c.contains("auth.jwt"):
            return "API anahtarı geçersiz. Ayarlar → İndirme sunucusu'ndan anahtarı kontrol edin."
        case c.contains("link.invalid"), c.contains("link.unsupported"), c.contains("service.unsupported"):
            return "Bu bağlantı desteklenmiyor ya da hatalı."
        case c.contains("content.too_long"):
            let m = Int((f.context?.limit ?? 0) / 60)
            return m > 0 ? "Video çok uzun (en fazla \(m) dk)." : "Video çok uzun."
        case c.contains("content.video.unavailable"), c.contains("content.post.unavailable"):
            return "İçerik bulunamadı ya da kaldırılmış\(svc)."
        case c.contains("content.post.private"), c.contains("content.video.private"):
            return "Bu gönderi gizli hesaba ait\(svc)."
        case c.contains("content.video.age"), c.contains("content.post.age"):
            return "Yaş kısıtlamalı içerik indirilemiyor\(svc)."
        case c.contains("content.video.region"):
            return "Bu içerik bölgede engelli\(svc)."
        case c.contains("youtube.login"), c.contains("youtube.token"), c.contains("youtube.decipher"):
            return "YouTube şu an sunucuya izin vermiyor. Biraz sonra tekrar deneyin; sürerse sunucuyu yeniden başlatın."
        case c.contains("rate_exceeded"):
            return "Çok fazla istek. Biraz bekleyip tekrar deneyin."
        case c.contains("fetch"):
            return "İçerik alınamadı\(svc). Bağlantıyı kontrol edip tekrar deneyin."
        case c.contains("capacity"):
            return "Sunucu şu an meşgul, biraz sonra tekrar deneyin."
        default:
            return "Sunucu hatası: \(c)"
        }
    }
}

extension AppStore {
    var cloudReady: Bool { !cloudURL.isEmpty && cloudKeySet }

    private var cloudBase: URL? {
        var s = cloudURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        if !s.hasSuffix("/") { s += "/" }
        return URL(string: s)
    }

    /// Saves the server address and key, then checks the server answers.
    func saveCloud(url: String, key: String?) async -> (Bool, String) {
        cloudURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key, !key.isEmpty {
            Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: "cobaltKey")
        }
        cloudKeySet = Keychain.get("cobaltKey") != nil
        guard let base = cloudBase, !cloudURL.isEmpty else { return (false, "Sunucu adresi girin") }
        do {
            var req = URLRequest(url: base)
            req.timeoutInterval = 15
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let info = obj["cobalt"] as? [String: Any] else {
                return (false, "Bu adreste indirme sunucusu bulunamadı")
            }
            let v = info["version"] as? String ?? "?"
            let n = (info["services"] as? [Any])?.count ?? 0
            guard cloudKeySet else { return (false, "Sunucu çalışıyor (v\(v)) ama API anahtarı girilmedi") }
            // Verify the key with a harmless invalid-link request.
            let (ok, msg) = await probeKey(base)
            return ok ? (true, "Bağlandı ✓ Sunucu v\(v) · \(n) site destekleniyor") : (false, msg)
        } catch {
            return (false, "Sunucuya ulaşılamadı: \(error.localizedDescription)")
        }
    }

    private func probeKey(_ base: URL) async -> (Bool, String) {
        do {
            let r = try await cobaltRequest(base, body: ["url": "https://example.com/zetx-test"])
            if let c = r.error?.code, c.contains("auth") { return (false, CobaltError.message(r.error)) }
            return (true, "")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func clearCloud() {
        cloudURL = ""
        Keychain.set(nil, for: "cobaltKey")
        cloudKeySet = false
    }

    private func cobaltRequest(_ base: URL, body: [String: Any]) async throws -> CobaltResponse {
        var req = URLRequest(url: base)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = Keychain.get("cobaltKey") { req.setValue("Api-Key \(key)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        do {
            return try JSONDecoder().decode(CobaltResponse.self, from: data)
        } catch {
            throw NetError.server("Sunucudan beklenmeyen yanıt geldi")
        }
    }

    /// Downloads straight to this iPhone through the user's own cobalt server.
    func cloudDownload(link: String, audioOnly: Bool, quality: String, bitrate: Int) async {
        guard let base = cloudBase else { return }
        let id = "cl-" + UUID().uuidString
        let label = audioOnly ? "MP3 \(bitrate) kbps" : "Video \(quality == "max" ? "en iyi" : quality + "p")"
        jobs.insert(MediaJob(id: id, title: link, label: label), at: 0)
        func set(_ pct: Double, _ msg: String, _ state: String = "dl") {
            guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
            jobs[i].pct = pct
            jobs[i].message = msg
            jobs[i].state = state
        }
        set(0, "Sunucu hazırlıyor…", "prep")
        var body: [String: Any] = [
            "url": link,
            "videoQuality": quality,
            "downloadMode": audioOnly ? "audio" : "auto",
            "audioFormat": "mp3",
            "audioBitrate": String(bitrate),
            "youtubeVideoCodec": "h264",
            "filenameStyle": "pretty",
            "localProcessing": "disabled",
        ]
        if !audioOnly { body["alwaysProxy"] = true }
        do {
            let r = try await cobaltRequest(base, body: body)
            var items: [(URL, String)] = []
            switch r.status {
            case "tunnel", "redirect":
                guard let s = r.url, let u = URL(string: s) else { throw NetError.server("İndirme adresi alınamadı") }
                items.append((u, r.filename ?? (audioOnly ? "ses.mp3" : "video.mp4")))
            case "picker":
                let stamp = Int(Date().timeIntervalSince1970)
                if audioOnly, let a = r.audio, let u = URL(string: a) {
                    items.append((u, r.audioFilename ?? "ses-\(stamp).mp3"))
                } else {
                    for (n, it) in (r.picker ?? []).enumerated() {
                        guard let u = URL(string: it.url) else { continue }
                        let ext = it.type == "photo" ? (["jpg", "jpeg", "png", "webp", "heic"].first { u.path.lowercased().hasSuffix($0) } ?? "jpg") : "mp4"
                        items.append((u, "zetx-\(stamp)-\(n + 1).\(ext)"))
                    }
                }
            case "error":
                throw NetError.server(CobaltError.message(r.error))
            default:
                throw NetError.server("Bu içerik telefonda işlenemiyor (\(r.status))")
            }
            guard !items.isEmpty else { throw NetError.server("Bu bağlantıda indirilebilir içerik yok") }
            if let i = jobs.firstIndex(where: { $0.id == id }), let first = items.first {
                jobs[i].title = items.count > 1 ? "\(items.count) öğe" : first.1
            }
            for (n, (u, name)) in items.enumerated() {
                if jobs.first(where: { $0.id == id })?.state == "error" { return }
                let prefix = items.count > 1 ? "\(n + 1)/\(items.count) · " : ""
                set(Double(n) / Double(items.count) * 100, prefix + "İndiriliyor…")
                let key = "\(id)-\(n)"
                cloudKeys[id] = key
                let tmp = try await Net.shared.download(u, key: key) { p in
                    Task { @MainActor in set((Double(n) + p) / Double(items.count) * 100, prefix + String(format: "%%%.0f", p * 100)) }
                }
                let dest = Files.unique(in: Files.inbox, name: name)
                try FileManager.default.moveItem(at: tmp, to: dest)
                await finishReceive(dest, from: "Bulut sunucu", key: "")
            }
            cloudKeys[id] = nil
            set(100, "✓ Tamamlandı" + (autoSave ? " · galeriye kaydedildi" : ""), "done")
        } catch {
            cloudKeys[id] = nil
            if jobs.first(where: { $0.id == id })?.state == "error" { return }
            let msg = (error as? URLError)?.code == .cancelled ? "İptal edildi" : error.localizedDescription
            set(0, "✗ " + msg, "error")
        }
    }
}

struct CloudMediaPanel: View {
    @EnvironmentObject var store: AppStore
    @State private var link = ""
    @State private var audio = false
    @State private var quality = "1080"
    @State private var bitrate = 320

    private let qualities = ["max", "2160", "1440", "1080", "720", "480", "360"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                TextField("https://…", text: $link)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Theme.bg)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Button {
                    if let s = UIPasteboard.general.string { link = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                } label: {
                    Image(systemName: "doc.on.clipboard").padding(12).background(Theme.card2).clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            Picker("Tür", selection: $audio) {
                Text("Video / Görsel").tag(false)
                Text("Sadece ses (MP3)").tag(true)
            }
            .pickerStyle(.segmented)

            if audio {
                Text("MP3 kalitesi").font(.caption).foregroundColor(Theme.mut)
                HStack {
                    ForEach([320, 256, 128], id: \.self) { b in chip("\(b) kbps", b == bitrate) { bitrate = b } }
                }
            } else {
                Text("Çözünürlük (videoda yoksa en yakını iner)").font(.caption).foregroundColor(Theme.mut)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(qualities, id: \.self) { q in chip(label(q), q == quality) { quality = q } }
                    }
                }
                Text("Fotoğraf gönderilerinde tüm görseller orijinal kalitede iner.").font(.caption2).foregroundColor(Theme.mut)
            }

            Button {
                let l = link.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !l.isEmpty else { return }
                link = ""
                Task { await store.cloudDownload(link: l, audioOnly: audio, quality: quality, bitrate: bitrate) }
            } label: {
                Label("İndir", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(GradientButtonStyle(enabled: !link.isEmpty))
            .disabled(link.isEmpty)
            Label("Bilgisayar gerekmez · kendi sunucunuz üzerinden", systemImage: "icloud.and.arrow.down")
                .font(.caption).foregroundColor(Theme.mut)
        }
        .card()
    }

    private func label(_ q: String) -> String {
        switch q {
        case "max": return "En iyi"
        case "2160": return "4K"
        case "1440": return "2K"
        default: return q + "p"
        }
    }

    private func chip(_ t: String, _ selected: Bool, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(.system(size: 13, weight: .bold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundColor(selected ? Theme.c1 : .white)
                .background(selected ? Theme.c1.opacity(0.12) : Theme.bg)
                .overlay(Capsule().stroke(selected ? Theme.c1 : Theme.line))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct CloudSettingsCard: View {
    @EnvironmentObject var store: AppStore
    @State private var url = ""
    @State private var key = ""
    @State private var busy = false
    @State private var result: (Bool, String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("İndirme sunucusu").font(.headline)
                Spacer()
                if store.cloudReady { Label("Hazır", systemImage: "checkmark.circle.fill").font(.caption).foregroundColor(Theme.ok) }
            }
            Text("Bilgisayar olmadan indirmek için kendi sunucunuzun adresini ve API anahtarını girin.")
                .font(.caption).foregroundColor(Theme.mut)
            TextField("https://….up.railway.app", text: $url)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(12).background(Theme.bg).clipShape(RoundedRectangle(cornerRadius: 12))
            SecureField(store.cloudKeySet ? "API anahtarı kayıtlı (değiştirmek için yazın)" : "API anahtarı", text: $key)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(12).background(Theme.bg).clipShape(RoundedRectangle(cornerRadius: 12))
            HStack {
                Button {
                    busy = true
                    Task {
                        result = await store.saveCloud(url: url, key: key)
                        key = ""
                        busy = false
                    }
                } label: {
                    HStack { if busy { ProgressView().tint(.white) }; Text("Kaydet ve test et") }
                }
                .buttonStyle(GradientButtonStyle(enabled: !busy && !url.isEmpty))
                .disabled(busy || url.isEmpty)
                if store.cloudReady {
                    Button("Kaldır", role: .destructive) { store.clearCloud(); url = ""; result = nil }
                        .font(.subheadline)
                }
            }
            if let r = result {
                Text(r.1).font(.caption).foregroundColor(r.0 ? Theme.ok : Theme.err)
            }
        }
        .card()
        .onAppear { url = store.cloudURL }
    }
}
