import Foundation
import MultipeerConnectivity
import UIKit

/// iPhone ↔ iPhone transfers without a PC, using the same peer-to-peer Wi-Fi
/// technology as AirDrop (MultipeerConnectivity).
final class PeerService: NSObject, ObservableObject {
    static let serviceType = "zetx-drop"

    struct NearbyPeer: Identifiable, Hashable {
        let peer: MCPeerID
        var connected: Bool
        var id: MCPeerID { peer }
        var name: String { peer.displayName }
    }

    @Published private(set) var nearby: [NearbyPeer] = []
    @Published var enabled = true

    var onReceived: ((URL, String, String) -> Void)?
    var onIncomingStart: ((String, String, String, Progress) -> Void)?
    var onIncomingFailed: ((String, String) -> Void)?

    private var myPeer: MCPeerID
    private var session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser
    private var browser: MCNearbyServiceBrowser
    private let token = UUID().uuidString
    private var tokens: [MCPeerID: String] = [:]
    private var found: Set<MCPeerID> = []

    init(name: String) {
        myPeer = MCPeerID(displayName: PeerService.clip(name))
        session = MCSession(peer: myPeer, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: myPeer, discoveryInfo: [:], serviceType: PeerService.serviceType)
        browser = MCNearbyServiceBrowser(peer: myPeer, serviceType: PeerService.serviceType)
        super.init()
        configure()
    }

    private static func clip(_ n: String) -> String {
        let t = n.trimmingCharacters(in: .whitespaces)
        let s = t.isEmpty ? "iPhone" : t
        // MCPeerID display names are limited to 63 bytes of UTF-8.
        var out = ""
        for ch in s {
            if (out + String(ch)).utf8.count > 60 { break }
            out.append(ch)
        }
        return out
    }

    private func configure() {
        advertiser = MCNearbyServiceAdvertiser(peer: myPeer, discoveryInfo: ["t": token], serviceType: PeerService.serviceType)
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    func start() {
        guard enabled else { return }
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
    }

    /// Restart with a new display name (after the user renames the device).
    func rename(_ name: String) {
        stop()
        session.disconnect()
        myPeer = MCPeerID(displayName: PeerService.clip(name))
        session = MCSession(peer: myPeer, securityIdentity: nil, encryptionPreference: .required)
        browser = MCNearbyServiceBrowser(peer: myPeer, serviceType: PeerService.serviceType)
        configure()
        found.removeAll()
        publish()
        start()
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if on { start() } else { stop(); session.disconnect(); found.removeAll(); publish() }
    }

    func isConnected(_ peer: MCPeerID) -> Bool { session.connectedPeers.contains(peer) }

    func reconnect(_ peer: MCPeerID) {
        guard !isConnected(peer) else { return }
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 20)
    }

    /// Sends a file; returns when the transfer finishes.
    func send(_ url: URL, to peer: MCPeerID, progress: @escaping (Double) -> Void) async throws {
        guard isConnected(peer) else {
            reconnect(peer)
            throw NetError.server("\(peer.displayName) henüz bağlanmadı, birkaç saniye sonra tekrar deneyin")
        }
        let name = url.lastPathComponent
        let once = Once()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let prog = session.sendResource(at: url, withName: name, toPeer: peer) { error in
                guard once.claim() else { return }
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
            if prog == nil, once.claim() { cont.resume(throwing: NetError.server("Gönderim başlatılamadı")) }
            let p = prog
            Task {
                while let p, !p.isFinished, !p.isCancelled {
                    progress(p.fractionCompleted)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }
        progress(1)
    }

    private func publish() {
        let connected = Set(session.connectedPeers)
        let list = found.union(connected).map { NearbyPeer(peer: $0, connected: connected.contains($0)) }
            .sorted { $0.name < $1.name }
        DispatchQueue.main.async { self.nearby = list }
    }
}

extension PeerService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async { self.handleFound(browser, peerID, info) }
    }

    private func handleFound(_ browser: MCNearbyServiceBrowser, _ peerID: MCPeerID, _ info: [String: String]?) {
        guard peerID != myPeer, browser === self.browser else { return }
        found.insert(peerID)
        let theirs = info?["t"] ?? ""
        tokens[peerID] = theirs
        publish()
        // Only one side invites, to avoid crossed invitations.
        if token < theirs || theirs.isEmpty {
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 20)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.found.remove(peerID)
            self.publish()
        }
    }
}

extension PeerService: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(enabled, enabled ? session : nil)
    }
}

extension PeerService: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { self.handleState(session, peerID, state) }
    }

    private func handleState(_ session: MCSession, _ peerID: MCPeerID, _ state: MCSessionState) {
        guard session === self.session else { return }
        if state == .notConnected, found.contains(peerID), enabled {
            let theirs = tokens[peerID] ?? ""
            if token < theirs || theirs.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, self.found.contains(peerID), !self.isConnected(peerID) else { return }
                    self.browser.invitePeer(peerID, to: self.session, withContext: nil, timeout: 20)
                }
            }
        }
        publish()
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        let key = "mc-\(peerID.hash)-\(resourceName)"
        let cb = onIncomingStart
        DispatchQueue.main.async { cb?(key, resourceName, peerID.displayName, progress) }
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        let key = "mc-\(peerID.hash)-\(resourceName)"
        guard error == nil, let localURL else {
            let cb = onIncomingFailed
            let msg = error?.localizedDescription ?? "Aktarım yarıda kaldı"
            DispatchQueue.main.async { cb?(key, msg) }
            return
        }
        // The temp file is deleted when this method returns, so move it now.
        let dest = Files.unique(in: Files.inbox, name: resourceName)
        do {
            try FileManager.default.moveItem(at: localURL, to: dest)
        } catch {
            let cb = onIncomingFailed
            DispatchQueue.main.async { cb?(key, error.localizedDescription) }
            return
        }
        let cb = onReceived
        let from = peerID.displayName
        DispatchQueue.main.async { cb?(dest, from, key) }
    }
}

/// Guards a continuation against being resumed twice.
final class Once {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
