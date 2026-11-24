import Foundation

/// LAN Nudge over the app's own PeerNetwork, with Cubi drawing what the app's overlay drew: a
/// request that passes the app's ReceiveGate becomes a `present`, and Cubi's answer decides the ack.
@MainActor
final class NudgeService {
    /// As long as Cubi's overlay stays up. After Cubi was asked (shown or not), another request in
    /// this time is answered rate-limited without asking: as the app does while its overlay shows,
    /// and so `present` lines never come faster than Cubi takes them.
    static let overlaySeconds: TimeInterval = 2
    /// At most this many peers are listed, and none whose id (a Bonjour service name) is longer.
    static let peerLimit = 50
    static let idLimit = 64

    private let network: PeerNetwork
    private let present: (_ effect: String, _ from: String) -> Bool
    private let peersChanged: () -> Void
    private var gate = ReceiveGate()
    private var lastAsked: Date?
    private(set) var peers: [Peer] = []

    init(network: PeerNetwork, present: @escaping (String, String) -> Bool, peersChanged: @escaping () -> Void) {
        self.network = network
        self.present = present
        self.peersChanged = peersChanged
        network.onRequest = { [weak self] in self?.receive(from: $0, $1) }
        network.onPeersChanged = { [weak self] in self?.setPeers($0) }
    }

    func setPeers(_ list: [Peer]) {
        peers = list.sorted { $0.name < $1.name }
        peersChanged()
    }

    func setDisplayName(_ name: String) { network.setDisplayName(name) }

    /// The app's own wording for the effect names Cubi knows.
    static func cubiEffect(_ effect: Effect) -> String {
        switch effect {
        case .cartoonShock: "zap"
        case .shake: "shake"
        case .knock: "knock"
        }
    }

    static func effect(cubi name: String) -> Effect? {
        Effect.allCases.first { cubiEffect($0) == name }
    }

    /// The app's list labels, by peer id: the name made plain, and when two plain names are the
    /// same, the first four hex digits of the advertised fingerprint hint ("?" if it has none).
    /// Every part comes from the peer's own Bonjour record, so the whole label is made plain again.
    static func labels(for peers: [Peer]) -> [String: String] {
        let names = peers.map { CubiChannel.plain($0.name, limit: CubiChannel.nameLimit, fallback: "未知裝置") }
        var labels: [String: String] = [:]
        for (peer, name) in zip(peers, names) {
            var label = name
            if names.filter({ $0 == name }).count > 1 {
                let hex = String(peer.hint.unicodeScalars.filter { ("0"..."9").contains($0) || ("A"..."F").contains($0) || ("a"..."f").contains($0) }.prefix(4))
                label += "・" + (hex.isEmpty ? "?" : hex)
            }
            labels[peer.id] = CubiChannel.plain(label, limit: CubiChannel.nameLimit + 5, fallback: "未知裝置")
        }
        return labels
    }

    /// The list for Cubi: `peerLimit` at most, ids no longer than `idLimit` bytes.
    static func list(_ peers: [Peer]) -> [[String: String]] {
        let labels = labels(for: peers)
        return peers.filter { $0.id.utf8.count <= idLimit }.prefix(peerLimit).map { ["id": $0.id, "name": labels[$0.id] ?? "未知裝置"] }
    }

    // MARK: - Receiving

    func receive(from sender: String, _ check: RequestCheck, now: Date = .now) -> AckStatus? {
        switch check {
        case .unreadable:
            return nil
        case .invalid:
            return .invalid
        case .valid(let id, let effect):
            // The name comes from the sender's own Bonjour record and can be spoofed, as in the app.
            let name = peers.first { sender.hasPrefix($0.hint) }.flatMap { Self.labels(for: peers)[$0.id] }
                ?? "未知裝置（\(CubiChannel.plain(String(sender.prefix(4)), limit: 4, fallback: "?"))）"
            let busy = lastAsked.map { now.timeIntervalSince($0) < Self.overlaySeconds } ?? false
            return gate.decide(sender: sender, id: id, now: now, muted: false, busy: busy) {
                lastAsked = now
                return present(Self.cubiEffect(effect), name)
            }
        }
    }

    // MARK: - Sending

    /// `call` action `send`, args `peer` (an id from the last `state`) and `effect` (knock, zap, shake).
    func send(peerID: String, effect name: String) async -> (ok: Bool, out: [String: Any]) {
        guard let effect = Self.effect(cubi: name) else { return (false, ["error": "effect 只能是 knock、zap、shake"]) }
        guard let peer = peers.first(where: { $0.id == peerID }) else { return (false, ["error": "附近沒有這台裝置"]) }
        let outcome = await network.send(effect, to: peer)
        return (outcome == .ack(.displayed), ["result": outcome.message])
    }
}
