import MultipeerConnectivity
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            SendView().tabItem { Label("Gönder", systemImage: "paperplane.fill") }.tag(0)
            MediaView().tabItem { Label("İndir", systemImage: "arrow.down.circle.fill") }.tag(1)
            InboxView()
                .tabItem { Label("Gelenler", systemImage: "tray.and.arrow.down.fill") }
                .badge(store.unseen)
                .tag(2)
            SettingsView().tabItem { Label("Ayarlar", systemImage: "gearshape.fill") }.tag(3)
            AboutView().tabItem { Label("Hakkında", systemImage: "info.circle.fill") }.tag(4)
        }
        .onChange(of: tab) { t in if t == 2 { store.unseen = 0 } }
        .overlay(alignment: .top) {
            if let t = store.toast {
                Text(t.text)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(Theme.card2)
                    .overlay(Capsule().stroke(t.ok ? Theme.ok : Theme.err, lineWidth: 1.5))
                    .clipShape(Capsule())
                    .shadow(radius: 12)
                    .padding(.top, 6)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { store.toast = nil }
            }
        }
        .animation(.spring(response: 0.35), value: store.toast)
    }
}

struct Screen<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Image("Logo").resizable().frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 9))
                        Text("ZETX DROP").font(.system(size: 17, weight: .heavy)).kerning(1.4)
                            .foregroundStyle(Theme.grad)
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 26, weight: .heavy))
                        Text(subtitle).font(.subheadline).foregroundColor(Theme.mut)
                    }
                    content
                }
                .padding(16)
                .padding(.bottom, 30)
            }
            .background(Theme.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

// MARK: - Send

struct PickedFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { try PickedFile(url: Files.stage($0.file)) }
        FileRepresentation(importedContentType: .image) { try PickedFile(url: Files.stage($0.file)) }
    }
}

struct SendView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var peers: PeerService
    @State private var target: AppStore.Target?
    @State private var askSource = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var preparing = false

    private let cols = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    var body: some View {
        Screen(title: "Gönder", subtitle: "Bir cihaza dokunun, fotoğraf veya dosya seçin.") {
            PCStatusCard()

            if store.nearbyEnabled {
                section("Yakındaki iPhone'lar", note: "Bilgisayar gerekmez") {
                    if peers.nearby.isEmpty {
                        empty("Yakında ZETX DROP açık iPhone yok. Diğer iPhone'da uygulamayı açın.")
                    } else {
                        LazyVGrid(columns: cols, spacing: 12) {
                            ForEach(peers.nearby) { p in
                                DeviceTile(name: p.name, symbol: "iphone", sub: p.connected ? "Hazır" : "Bağlanıyor…", ready: p.connected) {
                                    if p.connected { pick(.nearby(p.peer)) } else { peers.reconnect(p.peer); store.show("Bağlanıyor, birkaç saniye sonra tekrar dokunun", ok: false) }
                                }
                            }
                        }
                    }
                }
            }

            if store.pc != nil {
                section("ZETX DROP ağı", note: "Bilgisayar üzerinden") {
                    LazyVGrid(columns: cols, spacing: 12) {
                        ForEach(store.remote) { d in
                            DeviceTile(name: d.name, symbol: d.symbol, sub: d.kindLabel, ready: true) {
                                pick(.pc(id: d.id, name: d.name))
                            }
                        }
                    }
                }
            }

            if preparing {
                HStack { ProgressView(); Text("Dosyalar hazırlanıyor…").foregroundColor(Theme.mut) }.card()
            }

            TransfersCard()
        }
        .confirmationDialog(target.map { "\($0.name) cihazına gönder" } ?? "", isPresented: $askSource, titleVisibility: .visible) {
            Button("Fotoğraf / Video") { showPhotos = true }
            Button("Dosyalar") { showFiles = true }
            Button("Vazgeç", role: .cancel) {}
        }
        .photosPicker(isPresented: $showPhotos, selection: $picked, maxSelectionCount: 100, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
        .onChange(of: picked) { items in
            guard !items.isEmpty, let t = target else { return }
            picked = []
            preparing = true
            Task {
                var urls: [URL] = []
                for it in items {
                    if let f = try? await it.loadTransferable(type: PickedFile.self) { urls.append(f.url) }
                }
                preparing = false
                if urls.count < items.count { store.show("\(items.count - urls.count) öğe okunamadı (iCloud'dan inmemiş olabilir)", ok: false) }
                store.send(urls, to: t)
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard let t = target, case .success(let list) = result else { return }
            var urls: [URL] = []
            for u in list {
                let ok = u.startAccessingSecurityScopedResource()
                if let s = try? Files.stage(u) { urls.append(s) }
                if ok { u.stopAccessingSecurityScopedResource() }
            }
            store.send(urls, to: t)
        }
    }

    private func pick(_ t: AppStore.Target) {
        target = t
        askSource = true
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, note: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(note).font(.caption).foregroundColor(Theme.mut)
            }
            c()
        }
        .card()
    }

    private func empty(_ t: String) -> some View {
        Text(t).font(.footnote).foregroundColor(Theme.mut).frame(maxWidth: .infinity).padding(.vertical, 8)
    }
}

struct DeviceTile: View {
    let name: String
    let symbol: String
    let sub: String
    let ready: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    Circle().fill(Theme.card2).frame(width: 62, height: 62)
                    Circle().stroke(ready ? Theme.c1 : Theme.line, lineWidth: 2).frame(width: 62, height: 62)
                    Image(systemName: symbol).font(.system(size: 26)).foregroundColor(Theme.c1)
                }
                .shadow(color: ready ? Theme.c1.opacity(0.35) : .clear, radius: 10)
                Text(name).font(.system(size: 13, weight: .bold)).lineLimit(1).foregroundColor(.white)
                Text(sub).font(.system(size: 11)).foregroundColor(Theme.mut)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

struct PCStatusCard: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer").font(.system(size: 22))
                .foregroundColor(store.pc != nil ? Theme.ok : Theme.mut)
            VStack(alignment: .leading, spacing: 2) {
                switch store.pcState {
                case .connected:
                    Text(store.pc?.name ?? "Bilgisayar").font(.subheadline.bold())
                    Text("Bilgisayara bağlı · \(store.pc?.host ?? "")").font(.caption).foregroundColor(Theme.mut)
                case .searching:
                    Text("Bilgisayar aranıyor…").font(.subheadline.bold())
                    Text("Aynı Wi-Fi'daki ZETX DROP bilgisayarları").font(.caption).foregroundColor(Theme.mut)
                case .notFound:
                    Text("Bilgisayar bulunamadı").font(.subheadline.bold())
                    Text("iPhone'lar arası aktarım yine çalışır. PC'de ZETX DROP'u açın.").font(.caption).foregroundColor(Theme.mut)
                }
            }
            Spacer()
            if store.pcState == .searching {
                ProgressView()
            } else if store.pc == nil {
                Button("Ara") { Task { await store.rescan(autoConnect: true) } }.font(.subheadline.bold())
            }
        }
        .card()
    }
}

struct TransfersCard: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        if !store.transfers.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Aktarımlar").font(.headline)
                    Spacer()
                    Button("Temizle") { store.transfers.removeAll { $0.state != .running } }.font(.caption)
                }
                ForEach(store.transfers.prefix(30)) { t in TransferRow(t: t) }
            }
            .card()
        }
    }
}

struct TransferRow: View {
    @EnvironmentObject var store: AppStore
    let t: TransferItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: t.direction == .incoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 26))
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(t.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(line).font(.caption).foregroundColor(isFailed ? Theme.err : Theme.mut).lineLimit(2)
                if t.state == .running {
                    ProgressView(value: t.progress).tint(Theme.c1)
                }
            }
            if t.state == .running, t.direction == .outgoing {
                Button { store.cancel(t) } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Theme.mut) }
            }
        }
        .padding(10)
        .background(Theme.bg.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var isFailed: Bool { if case .failed = t.state { return true }; return false }
    private var color: Color {
        switch t.state {
        case .done: return Theme.ok
        case .failed: return Theme.err
        case .running: return Theme.c1
        }
    }
    private var line: String {
        let dir = t.direction == .incoming ? "← \(t.peer)" : "→ \(t.peer)"
        switch t.state {
        case .running: return t.detail.isEmpty ? "\(dir) · başlıyor…" : "\(dir) · \(t.detail)"
        case .done: return "✓ \(dir) · \(t.detail)"
        case .failed(let m): return "✗ \(m)"
        }
    }
}

// MARK: - Media

struct MediaView: View {
    @EnvironmentObject var store: AppStore
    @State private var link = ""
    @State private var info: MediaInfo?
    @State private var busy = false
    @State private var mode = "video"
    @State private var height = 0
    @State private var bitrate = 320
    @State private var compat = true
    @State private var target = "self"

    var body: some View {
        Screen(title: "Medya İndir", subtitle: "Instagram, YouTube, TikTok, X… bağlantısını yapıştırın.") {
            if store.pc == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Bilgisayar gerekli", systemImage: "desktopcomputer").font(.headline)
                    Text("Videoları bilgisayardaki ZETX DROP indirir ve iPhone'unuza gönderir. Bilgisayarda programı açın; aynı Wi-Fi'da olun.")
                        .font(.footnote).foregroundColor(Theme.mut)
                }
                .card()
            }
            if let b = store.toolBanner {
                Text(b).font(.footnote).card()
            }
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    TextField("https://…", text: $link)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(Theme.bg)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Button {
                        if let s = UIPasteboard.general.string { link = s.trimmingCharacters(in: .whitespacesAndNewlines); analyze() }
                    } label: {
                        Image(systemName: "doc.on.clipboard").padding(12).background(Theme.card2).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                Button(action: analyze) {
                    HStack { if busy { ProgressView().tint(.white) }; Text(busy ? "Analiz ediliyor…" : "Analiz Et") }
                }
                .buttonStyle(GradientButtonStyle(enabled: !busy && store.pc != nil))
                .disabled(busy || store.pc == nil || link.isEmpty)
            }
            .card()

            if let info { options(info) }

            if !store.jobs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("İndirmeler").font(.headline)
                    ForEach(store.jobs) { j in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(j.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Spacer()
                                if j.state != "done" && j.state != "error" {
                                    Button { store.cancelJob(j) } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Theme.mut) }
                                }
                            }
                            Text("\(j.label) · \(j.message)").font(.caption).foregroundColor(j.state == "error" ? Theme.err : Theme.mut).lineLimit(3)
                            if j.state != "done" && j.state != "error" { ProgressView(value: j.pct, total: 100).tint(Theme.c1) }
                        }
                        .padding(10).background(Theme.bg.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .card()
            }
            Text("Yalnızca indirme hakkına sahip olduğunuz içerikleri indirin.").font(.caption2).foregroundColor(Theme.mut)
        }
    }

    @ViewBuilder
    private func options(_ i: MediaInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                if let t = i.thumbnail, let u = URL(string: t) {
                    AsyncImage(url: u) { img in img.resizable().scaledToFill() } placeholder: { Theme.bg }
                        .frame(width: 96, height: 64).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(i.title?.isEmpty == false ? i.title! : (i.imageOnly == true ? "Görsel gönderi" : "Medya")).font(.subheadline.bold()).lineLimit(3)
                    Text([i.site, i.uploader].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundColor(Theme.mut)
                }
            }
            Picker("Tür", selection: $mode) {
                Text("Video").tag("video")
                Text("MP3").tag("mp3")
                Text("Görsel").tag("image")
            }
            .pickerStyle(.segmented)

            if mode == "video" {
                Text("Çözünürlük").font(.caption).foregroundColor(Theme.mut)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        chip("En iyi", selected: height == 0) { height = 0 }
                        ForEach(i.heights ?? [], id: \.self) { h in
                            chip(resLabel(h), selected: height == h) { height = h }
                        }
                    }
                }
                Toggle("iPhone uyumlu (H.264 MP4)", isOn: $compat).font(.subheadline)
            } else if mode == "mp3" {
                Text("MP3 kalitesi").font(.caption).foregroundColor(Theme.mut)
                HStack {
                    ForEach([320, 256, 192, 128], id: \.self) { b in chip("\(b) kbps", selected: bitrate == b) { bitrate = b } }
                }
            } else {
                Text("Gönderideki tüm fotoğraflar orijinal kalitede indirilir.").font(.caption).foregroundColor(Theme.mut)
            }

            Picker("Nereye", selection: $target) {
                Text("Bu iPhone (galeriye)").tag("self")
                ForEach(store.remote) { d in Text("\(d.name) · \(d.kindLabel)").tag(d.id) }
            }
            .pickerStyle(.menu)

            if let n = i.note, i.imageOnly == true, !n.isEmpty {
                Text("Video bulunamadı, Görsel modu seçildi.").font(.caption).foregroundColor(.yellow)
            }

            Button {
                let tgt = target == "self" ? store.clientID : target
                let label = mode == "mp3" ? "MP3 \(bitrate) kbps" : mode == "image" ? "Görsel" : "Video \(height == 0 ? "en iyi" : resLabel(height))"
                Task { await store.startMedia(link: link, mode: mode, height: height, bitrate: bitrate, compat: compat, target: tgt, title: i.title ?? link, label: label) }
            } label: {
                Label("İndir", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(GradientButtonStyle())
        }
        .card()
    }

    private func chip(_ t: String, selected: Bool, _ a: @escaping () -> Void) -> some View {
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

    private func resLabel(_ h: Int) -> String {
        h >= 4320 ? "8K" : h >= 2160 ? "4K" : h >= 1440 ? "2K" : "\(h)p"
    }

    private func analyze() {
        let l = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty, !busy else { return }
        busy = true
        info = nil
        Task {
            defer { busy = false }
            do {
                let i = try await store.mediaInfo(l)
                info = i
                let hs = i.heights ?? []
                height = hs.first(where: { $0 <= 1080 }) ?? hs.first ?? 0
                mode = i.imageOnly == true ? "image" : (hs.isEmpty && i.hasVideo != true ? "mp3" : "video")
            } catch {
                store.show(error.localizedDescription, ok: false)
            }
        }
    }
}

// MARK: - Inbox

struct InboxView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Screen(title: "Gelenler", subtitle: store.autoSave ? "Fotoğraf ve videolar otomatik olarak galeriye kaydedilir." : "Gelen dosyalar") {
            if store.inbox.isEmpty {
                Text("Henüz gelen dosya yok").foregroundColor(Theme.mut).frame(maxWidth: .infinity).padding(30).card()
            } else {
                VStack(spacing: 10) {
                    ForEach(store.inbox) { item in InboxRow(item: item) }
                }
            }
            Text("Diğer dosyalar: Dosyalar uygulaması → iPhone'umda → ZETX DROP → Gelenler").font(.caption).foregroundColor(Theme.mut)
        }
    }
}

struct InboxRow: View {
    @EnvironmentObject var store: AppStore
    let item: ReceivedItem

    var body: some View {
        HStack(spacing: 12) {
            thumb
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text("\(item.from) · \(formatSize(item.size))").font(.caption).foregroundColor(Theme.mut)
                if item.savedToPhotos {
                    Label("Galeride", systemImage: "checkmark.circle.fill").font(.caption2).foregroundColor(Theme.ok)
                }
            }
            Spacer()
            Menu {
                ShareLink(item: item.url) { Label("Paylaş / Aç", systemImage: "square.and.arrow.up") }
                if FileKind.isMedia(item.name), !item.savedToPhotos {
                    Button { Task { await store.saveToPhotos(item) } } label: { Label("Galeriye kaydet", systemImage: "photo.on.rectangle") }
                }
                Button(role: .destructive) { store.delete(item) } label: { Label("Sil", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 22)).foregroundColor(Theme.c1)
            }
        }
        .padding(12)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }

    @ViewBuilder private var thumb: some View {
        if FileKind.isImage(item.name), let img = UIImage(contentsOfFile: item.url.path) {
            Image(uiImage: img).resizable().scaledToFill().frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            Image(systemName: FileKind.symbol(item.name)).font(.system(size: 20)).foregroundColor(Theme.c1)
                .frame(width: 46, height: 46).background(Theme.card2).clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var name = ""
    @State private var manual = ""
    @State private var scanning = false

    var body: some View {
        Screen(title: "Ayarlar", subtitle: "Cihaz adı diğer cihazlarda böyle görünür.") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Cihaz adı").font(.caption).foregroundColor(Theme.mut)
                HStack {
                    TextField("iPhone", text: $name).padding(12).background(Theme.bg).clipShape(RoundedRectangle(cornerRadius: 12))
                    Button("Kaydet") { store.rename(name); store.show("Kaydedildi") }.font(.subheadline.bold())
                }
            }
            .card()
            .onAppear { name = store.deviceName }

            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $store.autoSave) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Otomatik galeriye kaydet").font(.subheadline.bold())
                        Text("Gelen fotoğraf ve videolar doğrudan Fotoğraflar'a kaydedilir").font(.caption).foregroundColor(Theme.mut)
                    }
                }
                Toggle(isOn: $store.nearbyEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Yakındaki iPhone'lar").font(.subheadline.bold())
                        Text("Bilgisayar olmadan iPhone'lar arası aktarım").font(.caption).foregroundColor(Theme.mut)
                    }
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Bilgisayar").font(.headline)
                    Spacer()
                    if scanning { ProgressView() } else {
                        Button("Yeniden ara") {
                            scanning = true
                            Task { await store.rescan(autoConnect: false); scanning = false }
                        }.font(.subheadline)
                    }
                }
                if let pc = store.pc {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.ok)
                        Text("\(pc.name) · \(pc.host)").font(.subheadline)
                        Spacer()
                        Button("Ayır") { store.disconnect() }.font(.caption).foregroundColor(Theme.err)
                    }
                }
                ForEach(store.foundPCs.filter { $0.host != store.pc?.host }) { p in
                    Button { store.connect(p) } label: {
                        HStack { Image(systemName: "desktopcomputer"); Text("\(p.name) · \(p.host)"); Spacer(); Text("Bağlan").bold() }
                            .font(.subheadline)
                    }
                }
                Text("Bulunamazsa PC'deki ZETX DROP'ta yazan adresi girin:").font(.caption).foregroundColor(Theme.mut)
                HStack {
                    TextField("192.168.1.20", text: $manual)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .padding(12).background(Theme.bg).clipShape(RoundedRectangle(cornerRadius: 12))
                    Button("Bağlan") { Task { if await store.connectManual(manual) { manual = "" } } }.font(.subheadline.bold())
                }
            }
            .card()
        }
    }
}

// MARK: - About

struct AboutView: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Sürüm \(v) (\(b))"
    }

    var body: some View {
        Screen(title: "Hakkında", subtitle: version) {
            VStack(spacing: 14) {
                Image("Logo").resizable().frame(width: 110, height: 110).clipShape(RoundedRectangle(cornerRadius: 26))
                    .shadow(color: Theme.violet.opacity(0.5), radius: 24)
                Text("ZETX DROP").font(.system(size: 28, weight: .heavy)).kerning(2).foregroundStyle(Theme.grad)
                Text("iPhone, bilgisayar ve telefonlar arasında AirDrop gibi kablosuz, yüksek hızlı dosya aktarımı; sosyal medyadan video, görsel ve MP3 indirme.")
                    .font(.subheadline).foregroundColor(Theme.mut).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .card()

            VStack(alignment: .leading, spacing: 14) {
                row("Geliştirici", Text("Volkan Sezer").bold())
                row("E-posta", Link("volkan.sezer@outlook.com.tr", destination: URL(string: "mailto:volkan.sezer@outlook.com.tr")!).bold())
                row("Instagram", Link("@zetxtv", destination: URL(string: "https://www.instagram.com/zetxtv/")!).bold())
                row("Kanal", Text("ZETXTV").bold())
            }
            .card()

            VStack(alignment: .leading, spacing: 10) {
                feature("bolt.fill", "Yüksek hız", "Dosyalar sıkıştırılmadan, orijinal kalitede aktarılır.")
                feature("iphone.radiowaves.left.and.right", "iPhone ↔ iPhone", "Bilgisayar olmadan, yakındaki iPhone'lara doğrudan.")
                feature("photo.on.rectangle.angled", "Doğrudan galeriye", "Gelen fotoğraf ve videolar otomatik Fotoğraflar'a kaydedilir.")
                feature("arrow.down.circle", "Medya indirici", "4K'ya kadar video, orijinal görsel, 320 kbps MP3.")
            }
            .card()

            Text("© 2026 Volkan Sezer · ZETX. Tüm hakları saklıdır.").font(.caption2).foregroundColor(Theme.mut).frame(maxWidth: .infinity)
        }
    }

    private func row<V: View>(_ k: String, _ v: V) -> some View {
        HStack { Text(k).foregroundColor(Theme.mut); Spacer(); v }.font(.subheadline)
    }

    private func feature(_ icon: String, _ t: String, _ d: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundColor(Theme.c1).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(t).font(.subheadline.bold())
                Text(d).font(.caption).foregroundColor(Theme.mut)
            }
        }
    }
}
