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
        case .ack(.queued): "已排隊，對方看完前一則就會顯示"
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
    /// Called with the sender's certificate fingerprint and the address it connected from; nil closes
    /// without replying.
    var onRequest: (_ sender: String, _ host: String?, _ check: RequestCheck) -> AckStatus? = { _, _, _ in nil }
    /// VPN on/off, Wi-Fi change, wake: remembered peers may be reachable (or gone) now.
    var onNetworkChanged: () -> Void = {}

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
            MainActor.assumeIsolated { self?.readvertise(); self?.onNetworkChanged() }
        }
        pathMonitor.start(queue: .main)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readvertise(); self?.onNetworkChanged() }
        }
    }

    func setDisplayName(_ name: String) {
        displayName = name
        readvertise()
    }

    // MARK: Receiving

    func startListener(port: NWEndpoint.Port? = NWEndpoint.Port(rawValue: Wire.preferredPort)) {
        // No pairing by product decision: any client certificate is accepted. TLS still encrypts and
        // gives each sender a stable fingerprint for the per-sender rate limit and de-duplication.
        let parameters = TLSSetup.parameters(identity: identity) { _ in true }
        guard let listener = try? (port.map { try NWListener(using: parameters, on: $0) } ?? NWListener(using: parameters)) else {
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
                    if port != nil, case .posix(.EADDRINUSE) = error { self?.startListener(port: nil); return }
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
                        var host: String?
                        if case .hostPort(let remote, _) = connection.endpoint { host = "\(remote)" }
                        guard let id = check.id, let status = self.onRequest(sender, host, check) else {
                            connection.cancel()
                            return
                        }
                        var ack = Ack(id: id, status: status)
                        if case .hello = check { ack.name = self.displayName }
                        FrameIO.send(ack, on: connection) { connection.cancel() }
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
    func send(_ effect: Effect, message: String? = nil, id: UUID = UUID(), to peer: Peer) async -> SendOutcome {
        await deliver(NudgeRequest(id: id, effect: effect, message: message), id: id, to: peer)
    }

    func sendReadReceipt(for id: UUID, to peer: Peer) async -> SendOutcome {
        await deliver(ReadReceipt(id: id), id: id, to: peer)
    }

    /// nil until the listener has a port to tell the peer.
    func hello(_ peer: Peer) async -> SendOutcome? {
        guard let port = listeningPort else { return nil }
        let id = UUID()
        return await deliver(Hello(id: id, port: port, name: displayName), id: id, to: peer)
    }

    /// Hellos to every other host of this Mac's VPN subnets on the preferred port, 32 at a time,
    /// accepting any certificate: the way to meet peers on the VPN that Bonjour never showed. nil when
    /// no VPN is connected (or the listener isn't up yet).
    func scanVPN() async -> [(fingerprint: String, name: String, host: String)]? {
        let hosts = LocalAddresses.vpnScanHosts()
        guard !hosts.isEmpty, let port = listeningPort else { return nil }
        var found: [(fingerprint: String, name: String, host: String)] = []
        for start in stride(from: 0, to: hosts.count, by: 32) {
            let batch = hosts[start..<min(start + 32, hosts.count)].map { host in Task { await greet(host, at: Wire.preferredPort, from: port) } }
            for task in batch {
                if let answer = await task.value { found.append(answer) }
            }
        }
        return found.filter { Fingerprint.hint($0.fingerprint) != ownHint }
    }

    func greet(_ host: String, at target: UInt16, from port: UInt16) async -> (fingerprint: String, name: String, host: String)? {
        guard let target = NWEndpoint.Port(rawValue: target) else { return nil }
        let id = UUID()
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: target)
        let reply = await withCheckedContinuation { continuation in
            SendAttempt(payload: Hello(id: id, port: port, name: displayName), id: id, deadline: .seconds(2),
                        continuation: continuation).start([endpoint]) { [identity] in
                TLSSetup.parameters(identity: identity) { _ in true }
            }
        }
        guard case .ack = reply.outcome, let fingerprint = reply.fingerprint,
              let name = NudgeMessage.sanitize(reply.name) else { return nil }
        return (fingerprint, name, host)
    }

    private func deliver(_ payload: some Encodable, id: UUID, to peer: Peer) async -> SendOutcome {
        await withCheckedContinuation { continuation in
            SendAttempt(payload: payload, id: id, continuation: continuation).start(peer.candidates) { [identity] in
                TLSSetup.parameters(identity: identity) { $0.hasPrefix(peer.hint) }
            }
        }.outcome
    }
}

/// Connects to every candidate address at once; the first that completes the mutual-TLS handshake
/// with the expected fingerprint carries the request and the rest are cancelled. Racing keeps a
/// full-tunnel VPN (LAN address blackholed, VPN address reachable) inside the 5-second budget.
@MainActor
private final class SendAttempt {
    private let payload: any Encodable
    private let id: UUID
    private let deadline: Duration
    private let continuation: CheckedContinuation<Reply, Never>
    private var connections: [NWConnection] = []
    private var failed: Set<ObjectIdentifier> = []
    private var winner: NWConnection?
    private var finished = false
    private var localNetworkDenied = false

    struct Reply {
        var outcome: SendOutcome
        /// The answering certificate and the name in its ack (answers to a `Hello` only).
        var fingerprint: String?
        var name: String?
    }

    init(payload: any Encodable, id: UUID, deadline: Duration = Wire.deadline, continuation: CheckedContinuation<Reply, Never>) {
        self.payload = payload
        self.id = id
        self.deadline = deadline
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
            try? await Task.sleep(for: deadline)
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
            FrameIO.send(payload, on: connection) {}
            FrameIO.readOne(connection) { [self] payload in
                guard let payload, let ack = try? JSONDecoder().decode(Ack.self, from: payload),
                      ack.version == Wire.version, ack.id == id else { return finish(.noAck) }
                finish(.ack(ack.status), fingerprint: TLSSetup.peerFingerprint(connection), name: ack.name)
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

    private func finish(_ outcome: SendOutcome, fingerprint: String? = nil, name: String? = nil) {
        guard !finished else { return }
        finished = true
        connections.forEach { $0.cancel() }
        continuation.resume(returning: Reply(outcome: outcome, fingerprint: fingerprint, name: name))
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

/// Peers met over Bonjour, a VPN scan or a hello, remembered so they can still be reached when Bonjour
/// can't see them (another Wi-Fi on the same VPN). Addresses come from Bonjour or from the connection
/// itself, never from a payload, so nobody can point this Mac at a third host.
// ponytail: anyone on the network can add itself with a hello; the cap evicts the oldest, so a flood of
// fake certificates could push real colleagues out. Keep Bonjour/scan entries apart if that happens.
struct KnownPeers: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var name: String
        /// Hosts only, most recently confirmed first.
        var addresses: [String]
        var port: UInt16
        var seen: Date
    }

    static let maxEntries = 50
    static let maxAge: TimeInterval = 30 * 86_400
    static let maxAddresses = 4
    /// By fingerprint hint.
    private(set) var entries: [String: Entry] = [:]

    /// A Bonjour sighting; skipped until its TXT record carries the port and addresses.
    mutating func met(_ peer: Peer, now: Date) {
        let hostPorts: [(host: String, port: UInt16)] = peer.candidates.compactMap {
            guard case .hostPort(let host, let port) = $0 else { return nil }
            return ("\(host)", port.rawValue)
        }
        guard let port = hostPorts.first?.port else { return }
        entries[peer.hint] = Entry(name: peer.name, addresses: Array(hostPorts.map(\.host).prefix(Self.maxAddresses)),
                                   port: port, seen: now)
        prune(now: now)
    }

    /// A verified sender (or scan answer) at `host`. False for a stranger that gave no name.
    mutating func heard(from hint: String, host: String, port: UInt16, name: String? = nil, now: Date) -> Bool {
        guard var entry = entries[hint] ?? name.map({ Entry(name: $0, addresses: [], port: port, seen: now) }) else { return false }
        if let name { entry.name = name }
        entry.addresses = Array(([host] + entry.addresses.filter { $0 != host }).prefix(Self.maxAddresses))
        entry.port = port
        entry.seen = now
        entries[hint] = entry
        prune(now: now)
        return true
    }

    mutating func touch(_ hint: String, now: Date) {
        entries[hint]?.seen = now
    }

    func peer(_ hint: String) -> Peer? {
        guard let entry = entries[hint], let port = NWEndpoint.Port(rawValue: entry.port) else { return nil }
        return Peer(id: "remembered-\(hint)", name: "\(entry.name)（VPN）", hint: hint,
                    candidates: entry.addresses.map { .hostPort(host: NWEndpoint.Host($0), port: port) })
    }

    mutating func prune(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.seen) < Self.maxAge }
        while entries.count > Self.maxEntries, let oldest = entries.min(by: { $0.value.seen < $1.value.seen })?.key {
            entries[oldest] = nil
        }
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

    /// Every other host of each VPN interface's subnet, at most its /24: wider VPN pools would take
    /// minutes and look like a sweep. Point-to-point /31–/32 links (Tailscale) have no neighbours.
    static func vpnScanHosts() -> [String] {
        vpnInterfaces().flatMap { scanHosts(address: $0.address, prefix: $0.prefix) }
    }

    static func scanHosts(address: UInt32, prefix: Int) -> [String] {
        guard (8...30).contains(prefix) else { return [] }
        let bits = max(prefix, 24)
        let mask = UInt32.max << (32 - bits)
        let network = address & mask
        return (network + 1..<(network | ~mask)).filter { $0 != address }.map {
            "\($0 >> 24).\($0 >> 16 & 255).\($0 >> 8 & 255).\($0 & 255)"
        }
    }

    private static func vpnInterfaces() -> [(address: UInt32, prefix: Int)] {
        var result: [(address: UInt32, prefix: Int)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var cursor = head
        while let ifa = cursor?.pointee {
            defer { cursor = ifa.ifa_next }
            let name = String(cString: ifa.ifa_name)
            guard ["utun", "ppp", "ipsec"].contains(where: name.hasPrefix), ifa.ifa_flags & UInt32(IFF_UP) != 0,
                  let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), let mask = ifa.ifa_netmask else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let bits = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }.nonzeroBitCount
            result.append((ip, bits))
        }
        return result
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
