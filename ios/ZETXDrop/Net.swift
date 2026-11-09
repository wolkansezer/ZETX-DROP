import Foundation

/// Delegate-based URLSession wrapper that reports upload/download progress
/// and exposes async/await completion.
final class Net: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate {
    static let shared = Net()

    private var session: URLSession!
    private let lock = NSLock()
    private var progress: [Int: (Double) -> Void] = [:]
    private var downloads: [Int: CheckedContinuation<URL, Error>] = [:]
    private var uploads: [Int: CheckedContinuation<(Data, Int), Error>] = [:]
    private var bodies: [Int: Data] = [:]
    private var tasks: [String: URLSessionTask] = [:]

    override init() {
        super.init()
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 60 * 60 * 12
        c.httpMaximumConnectionsPerHost = 4
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }

    private func locked<T>(_ f: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f()
    }

    func cancel(_ key: String) {
        let t = locked { tasks.removeValue(forKey: key) }
        t?.cancel()
    }

    func download(_ url: URL, key: String, progress: @escaping (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let task = session.downloadTask(with: url)
            locked {
                self.progress[task.taskIdentifier] = progress
                self.downloads[task.taskIdentifier] = cont
                self.tasks[key] = task
            }
            task.resume()
        }
    }

    func upload(_ request: URLRequest, file: URL, key: String, progress: @escaping (Double) -> Void) async throws -> (Data, Int) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, Int), Error>) in
            let task = session.uploadTask(with: request, fromFile: file)
            locked {
                self.progress[task.taskIdentifier] = progress
                self.uploads[task.taskIdentifier] = cont
                self.tasks[key] = task
            }
            task.resume()
        }
    }

    // MARK: delegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let cb = locked { progress[task.taskIdentifier] }
        cb?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let cb = locked { progress[downloadTask.taskIdentifier] }
        cb?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier
        let cont = locked { downloads.removeValue(forKey: id) }
        guard let cont else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 206 else {
            cont.resume(throwing: NetError.http(status))
            return
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("dl-" + UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            cont.resume(returning: dest)
        } catch {
            cont.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        locked { bodies[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        let (dl, up, body) = locked { () -> (CheckedContinuation<URL, Error>?, CheckedContinuation<(Data, Int), Error>?, Data) in
            progress.removeValue(forKey: id)
            for (k, t) in tasks where t.taskIdentifier == id { tasks.removeValue(forKey: k) }
            return (downloads.removeValue(forKey: id), uploads.removeValue(forKey: id), bodies.removeValue(forKey: id) ?? Data())
        }
        if let dl {
            dl.resume(throwing: error ?? NetError.http(0))
        }
        if let up {
            if let error {
                up.resume(throwing: error)
            } else {
                up.resume(returning: (body, (task.response as? HTTPURLResponse)?.statusCode ?? 0))
            }
        }
    }
}

enum NetError: LocalizedError {
    case http(Int)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .http(let c): return c == 0 ? "Bağlantı kesildi" : "Sunucu hatası (\(c))"
        case .server(let m): return m
        }
    }
}

/// Finds the Wi-Fi IPv4 address and scans the /24 for ZETX DROP PCs.
enum LAN {
    static func wifiAddress() -> (ip: UInt32, mask: UInt32)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var fallback: (UInt32, UInt32)?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            var mask: UInt32 = 0xFFFF_FF00
            if let m = ifa.ifa_netmask {
                mask = m.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            }
            if name == "en0" { return (ip, mask) }
            if name.hasPrefix("en") || name.hasPrefix("bridge") { fallback = (ip, mask) }
        }
        return fallback.map { (ip: $0.0, mask: $0.1) }
    }

    static func str(_ ip: UInt32) -> String {
        "\(ip >> 24 & 255).\(ip >> 16 & 255).\(ip >> 8 & 255).\(ip & 255)"
    }

    static func candidates() -> [String] {
        guard let (ip, _) = wifiAddress() else { return [] }
        let base = ip & 0xFFFF_FF00
        return (1...254).map { base | UInt32($0) }.filter { $0 != ip }.map(str)
    }

    static let probeSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1.6
        c.timeoutIntervalForResource = 3
        c.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: c)
    }()

    static func probe(_ host: String) async -> PCInfo? {
        guard let url = URL(string: "http://\(host):\(PCInfo.port)/api/info") else { return nil }
        do {
            let (data, resp) = try await probeSession.data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            var info = try JSONDecoder().decode(PCInfo.self, from: data)
            guard info.app == "ZETX DROP" else { return nil }
            info.host = host
            return info
        } catch {
            return nil
        }
    }

    static func scan() async -> [PCInfo] {
        let hosts = candidates()
        return await withTaskGroup(of: PCInfo?.self) { group in
            var results: [PCInfo] = []
            var it = hosts.makeIterator()
            // Limit concurrency to keep the radio happy.
            for _ in 0..<48 {
                if let h = it.next() { group.addTask { await probe(h) } }
            }
            while let r = await group.next() {
                if let r { results.append(r) }
                if let h = it.next() { group.addTask { await probe(h) } }
            }
            return results.sorted { $0.name < $1.name }
        }
    }
}
