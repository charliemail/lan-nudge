import AppKit
import dnssd
import Foundation
import Network

struct Peer: Identifiable, Hashable {
    /// Bonjour service name.
    let id: String
    let name: String
    /// Fingerprint prefix from TXT; a hint only, trust is decided by the TLS handshake.
    let hint: String
    /// Bonjour endpoint first, then the advertised LAN and VPN addresses.
    let candidates: [NWEndpoint]
}

enum SendOutcome: Equatable {
    case ack(AckStatus)
    case noAck
    case localNetworkDenied

    var message: String {
        switch self {
        case .ack(.displayed): "已觸發"
        case .ack(.muted): "對方暫停接收"
        case .ack(.rateLimited): "請稍後再試"
        case .ack(.unavailable): "對方目前無法顯示提醒"
        case .ack(.invalid): "版本不相容"
        case .noAck: "未收到確認（對方可能離線，或網路被擋）"
        case .localNetworkDenied: "未允許區域網路存取"
        }
    }
}

/// Bonjour listener + browser and the short-lived mTLS connections. Everything runs on the main
/// queue so pairing state and the receive gate have a single writer.
@MainActor
final class PeerNetwork {
    var onPeersChanged: ([Peer]) -> Void = { _ in }
    var onProblem: (String?) -> Void = { _ in }
    /// Called with the sender's certificate fingerprint; nil closes without replying.
    var onRequest: (_ sender: String, _ check: RequestCheck) -> AckStatus? = { _, _ in nil }

    private let identity: SecIdentity
    private let ownHint: String
    private let advertise: Bool
    private var displayName: String
    private var listener: NWListener?
    private var browser: NWBrowser?
    private let pathMonitor = NWPathMonitor()
    /// Tracked per source so a recovered listener clears its own error without hiding the browser's.
    private var listenerProblem: String? { didSet { onProblem(listenerProblem ?? browserProblem) } }
    private var browserProblem: String? { didSet { onProblem(listenerProblem ?? browserProblem) } }

    /// `advertise: false` skips Bonjour so tests can exercise mutual TLS over loopback only.
    init(identity: LocalIdentity, displayName: String, advertise: Bool = true) {
        self.identity = identity.identity
        self.ownHint = Fingerprint.hint(identity.fingerprint)
        self.displayName = displayName
        self.advertise = advertise
    }

    var listeningPort: UInt16? { listener?.port?.rawValue }

    func start() {
        startListener()
        startBrowser()
        // VPN on/off and Wi-Fi changes alter the address list peers should try.
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            MainActor.assumeIsolated { self?.readvertise() }
        }
        pathMonitor.start(queue: .main)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readvertise() }
        }
    }

    func setDisplayName(_ name: String) {
        displayName = name
        readvertise()
    }

    // MARK: Receiving

    func startListener() {
        // No pairing by product decision: any client certificate is accepted. TLS still encrypts and
        // gives each sender a stable fingerprint for the per-sender rate limit and de-duplication.
        let parameters = TLSSetup.parameters(identity: identity) { _ in true }
        guard let listener = try? NWListener(using: parameters) else {
            listenerProblem = "無法開始接收提醒"
            return
        }
        if advertise { listener.service = service(port: nil) }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    self?.listenerProblem = nil
                    self?.readvertise()
                case .failed(let error):
                    listener?.cancel()
                    self?.listener = nil
                    self?.listenerProblem = Self.describe(error)
                    self?.restart { $0.startListener() }
                default:
                    break
                }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    /// The port is only known once the listener is ready; re-setting `service` updates the TXT record.
    private func readvertise() {
        guard advertise, let listener, let port = listener.port?.rawValue else { return }
        listener.service = service(port: port)
    }

    private func service(port: UInt16?) -> NWListener.Service {
        var txt = ["v": String(Wire.version), "fp": ownHint, "name": LocalAddresses.txtSafe(displayName)]
        if let port {
            txt["port"] = String(port)
            txt["addrs"] = LocalAddresses.advertised()
        }
        return NWListener.Service(name: "LANNudge-\(ownHint)", type: Wire.bonjourType, domain: nil, txtRecord: NWTXTRecord(txt))
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    guard let sender = TLSSetup.peerFingerprint(connection) else {
                        connection.cancel()
                        return
                    }
                    FrameIO.readOne(connection) { payload in
                        let check = payload.map(RequestCheck.init) ?? .unreadable
                        guard let id = check.id, let status = self.onRequest(sender, check) else {
                            connection.cancel()
                            return
                        }
                        FrameIO.send(Ack(id: id, status: status), on: connection) { connection.cancel() }
                    }
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        Task {
            try? await Task.sleep(for: Wire.deadline)
            connection.cancel()
        }
    }

    // MARK: Discovery

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Wire.bonjourType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onPeersChanged(results.compactMap(Self.peer).filter { $0.hint != self.ownHint })
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    self?.browserProblem = nil
                case .waiting(let error):
                    self?.browserProblem = Self.describe(error)
                case .failed(let error):
                    browser?.cancel()
                    self?.browser = nil
                    self?.browserProblem = Self.describe(error)
                    self?.restart { $0.startBrowser() }
                default:
                    break
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func restart(_ action: @escaping (PeerNetwork) -> Void) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if let self { action(self) }
        }
    }

    // ponytail: peers on another protocol version are hidden rather than listed as incompatible.
    private static func peer(_ result: NWBrowser.Result) -> Peer? {
        guard case .service(let name, _, _, _) = result.endpoint,
              case .bonjour(let txt) = result.metadata,
              txt["v"] == String(Wire.version), let hint = txt["fp"] else { return nil }
        var fallbacks: [NWEndpoint] = []
        if let portText = txt["port"], let port = NWEndpoint.Port(portText), let addrs = txt["addrs"] {
            fallbacks = addrs.split(separator: ",").map { .hostPort(host: NWEndpoint.Host(String($0)), port: port) }
        }
        return Peer(id: name, name: txt["name"] ?? name, hint: hint, candidates: [result.endpoint] + fallbacks)
    }

    private static func describe(_ error: NWError) -> String {
        if case .dns(let code) = error, Int(code) == kDNSServiceErr_PolicyDenied {
            return "未允許區域網路存取：請到「系統設定 → 隱私權與安全性 → 區域網路」開啟 LAN Nudge。"
        }
        return "區網連線異常（\(error)）"
    }

    // MARK: Sending

    /// The receiver must present a certificate whose fingerprint starts with the peer's advertised
    /// hint, so a spoofed Bonjour record can't redirect the nudge to another machine.
    func send(_ effect: Effect, to peer: Peer) async -> SendOutcome {
        let request = NudgeRequest(id: UUID(), effect: effect)
        return await withCheckedContinuation { continuation in
            SendAttempt(request: request, continuation: continuation).start(peer.candidates) { [identity] in
                TLSSetup.parameters(identity: identity) { $0.hasPrefix(peer.hint) }
            }
        }
    }
}

/// Connects to every candidate address at once; the first that completes the mutual-TLS handshake
/// with the expected fingerprint carries the request and the rest are cancelled. Racing keeps a
/// full-tunnel VPN (LAN address blackholed, VPN address reachable) inside the 5-second budget.
@MainActor
private final class SendAttempt {
    private let request: NudgeRequest
    private let continuation: CheckedContinuation<SendOutcome, Never>
    private var connections: [NWConnection] = []
    private var failed: Set<ObjectIdentifier> = []
    private var winner: NWConnection?
    private var finished = false
    private var localNetworkDenied = false

    init(request: NudgeRequest, continuation: CheckedContinuation<SendOutcome, Never>) {
        self.request = request
        self.continuation = continuation
    }

    func start(_ candidates: [NWEndpoint], parameters: () -> NWParameters) {
        guard !candidates.isEmpty else { return finish(.noAck) }
        for endpoint in candidates {
            let connection = NWConnection(to: endpoint, using: parameters())
            connections.append(connection)
            connection.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.handle(state, of: connection) }
            }
            connection.start(queue: .main)
        }
        // Holds self until the deadline even if every connection is already gone.
        Task {
            try? await Task.sleep(for: Wire.deadline)
            finish(.noAck)
        }
    }

    private func handle(_ state: NWConnection.State, of connection: NWConnection) {
        guard !finished else { return }
        switch state {
        case .ready:
            guard winner == nil else { return connection.cancel() }
            winner = connection
            for other in connections where other !== connection { other.cancel() }
            FrameIO.send(request, on: connection) {}
            FrameIO.readOne(connection) { [self] payload in
                guard let payload, let ack = try? JSONDecoder().decode(Ack.self, from: payload),
                      ack.version == Wire.version, ack.id == request.id else { return finish(.noAck) }
                finish(.ack(ack.status))
            }
        case .waiting:
            if connection.currentPath?.unsatisfiedReason == .localNetworkDenied { localNetworkDenied = true }
            candidateFailed(connection)
        case .failed:
            candidateFailed(connection)
        default:
            break
        }
    }

    private func candidateFailed(_ connection: NWConnection) {
        failed.insert(ObjectIdentifier(connection))
        connection.cancel()
        if connection === winner { return finish(.noAck) }
        if winner == nil, failed.count == connections.count {
            finish(localNetworkDenied ? .localNetworkDenied : .noAck)
        }
    }

    private func finish(_ outcome: SendOutcome) {
        guard !finished else { return }
        finished = true
        connections.forEach { $0.cancel() }
        continuation.resume(returning: outcome)
    }
}

@MainActor
enum FrameIO {
    /// Reads until one complete frame arrives; nil on close, error or a bad length.
    static func readOne(_ connection: NWConnection, decoder: FrameCodec.Decoder = .init(),
                        done: @escaping @MainActor (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4 + Wire.maxPayloadBytes) { data, _, isComplete, error in
            MainActor.assumeIsolated {
                var decoder = decoder
                if let data, !data.isEmpty {
                    guard let frames = try? decoder.push(data) else { return done(nil) }
                    if let first = frames.first { return done(first) }
                }
                if isComplete || error != nil { return done(nil) }
                readOne(connection, decoder: decoder, done: done)
            }
        }
    }

    static func send<T: Encodable>(_ message: T, on connection: NWConnection, then: @escaping @MainActor () -> Void) {
        guard let frame = try? FrameCodec.encode(message) else { return then() }
        connection.send(content: frame, completion: .contentProcessed { _ in
            MainActor.assumeIsolated { then() }
        })
    }
}

enum LocalAddresses {
    /// LAN interfaces first, then the rest (VPN). Virtual bridges are skipped: other Macs can't reach them.
    /// Capped well under the 255-byte TXT value limit.
    static func advertised() -> String {
        let usable = ipv4Interfaces().filter { !$0.name.hasPrefix("bridge") && !$0.name.hasPrefix("vmnet") }
        let ordered = usable.filter { $0.name.hasPrefix("en") } + usable.filter { !$0.name.hasPrefix("en") }
        var out: [String] = []
        for entry in ordered where (out + [entry.address]).joined(separator: ",").utf8.count <= 200 {
            out.append(entry.address)
        }
        return out.joined(separator: ",")
    }

    static func txtSafe(_ text: String) -> String {
        var out = ""
        for character in text {
            guard out.utf8.count + String(character).utf8.count <= 200 else { break }
            out.append(character)
        }
        return out
    }

    private static func ipv4Interfaces() -> [(name: String, address: String)] {
        var result: [(name: String, address: String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var cursor = head
        while let ifa = cursor?.pointee {
            defer { cursor = ifa.ifa_next }
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append((String(cString: ifa.ifa_name),
                               String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)))
            }
        }
        return result
    }
}
