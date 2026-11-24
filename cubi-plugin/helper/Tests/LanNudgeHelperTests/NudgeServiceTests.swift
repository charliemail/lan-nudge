import Foundation
import Network
import Security
import Testing
@testable import LanNudgeHelper

// Over loopback with real keychain identities, as the app's MutualTLSTests does: two throwaway
// identities in the login keychain, deleted before and after. Their labels are the plugin's own,
// apart from the app's "LAN Nudge Test A/B" and both apps' "… Identity".

@MainActor
@Suite(.serialized)
struct NudgeServiceTests {
    private static let labels = ["Cubi LAN Nudge Test A", "Cubi LAN Nudge Test B"]

    private static func deleteIdentity(_ label: String) {
        SecItemDelete([kSecClass: kSecClassCertificate, kSecAttrLabel: label] as CFDictionary)
        SecItemDelete([kSecClass: kSecClassKey, kSecAttrLabel: label] as CFDictionary)
    }

    @Test func effectsMapBothWays() {
        for effect in Effect.allCases {
            #expect(NudgeService.effect(cubi: NudgeService.cubiEffect(effect)) == effect)
        }
        #expect(NudgeService.cubiEffect(.cartoonShock) == "zap")
        #expect(NudgeService.effect(cubi: "cartoonShock") == nil)
    }

    @Test func cubisAnswerDecidesTheAckAndSendingReportsTheOutcome() async throws {
        defer { Self.labels.forEach(Self.deleteIdentity) }
        Self.labels.forEach(Self.deleteIdentity)
        let a = try LocalIdentity.loadOrCreate(label: Self.labels[0])
        let b = try LocalIdentity.loadOrCreate(label: Self.labels[1])

        // The receiving side: Cubi's answer is whatever `shown` says.
        var shown = true
        var asked: [(String, String)] = []
        let receiverNetwork = PeerNetwork(identity: b, displayName: "B", advertise: false)
        let receiver = NudgeService(network: receiverNetwork, present: { effect, from in
            asked.append((effect, from)); return shown
        }, peersChanged: {})
        receiverNetwork.startListener()
        var port: UInt16?
        for _ in 0..<50 where port == nil {
            try await Task.sleep(for: .milliseconds(20))
            port = receiverNetwork.listeningPort
        }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: try #require(port))!)

        // The sending side, with the receiver as its one peer.
        let senderNetwork = PeerNetwork(identity: a, displayName: "A", advertise: false)
        let sender = NudgeService(network: senderNetwork, present: { _, _ in true }, peersChanged: {})
        sender.setPeers([Peer(id: "LANNudge-B", name: "B", hint: Fingerprint.hint(b.fingerprint), candidates: [endpoint])])

        // Over the network: drawn, triggered; an unknown sender is named by its fingerprint, as in the app.
        var result = await sender.send(peerID: "LANNudge-B", effect: "zap")
        #expect(result.ok && result.out["result"] as? String == SendOutcome.ack(.displayed).message)
        #expect(asked.count == 1 && asked[0].0 == "zap" && asked[0].1 == "未知裝置（\(a.fingerprint.prefix(4))）")
        // Right after: rate-limited, and Cubi is not asked again.
        result = await sender.send(peerID: "LANNudge-B", effect: "shake")
        #expect(!result.ok && result.out["result"] as? String == SendOutcome.ack(.rateLimited).message)
        #expect(asked.count == 1)

        // A peer it does not know, or an effect Cubi does not have: refused before the network.
        #expect(await sender.send(peerID: "nobody", effect: "zap").ok == false)
        #expect(await sender.send(peerID: "LANNudge-B", effect: "cartoonShock").ok == false)

        // In time (fresh senders, so the per-sender limit stays out of it; past the sends above):
        // once Cubi was asked, drawn or not, others are told to wait for overlaySeconds and Cubi is
        // not asked (F-P2-4); then it is asked again.
        let t0 = Date().addingTimeInterval(10)
        let o = NudgeService.overlaySeconds
        func ask(_ n: Int, _ after: TimeInterval) -> AckStatus? {
            receiver.receive(from: a.fingerprint + String(n), .valid(id: UUID(), effect: .knock), now: t0.addingTimeInterval(after))
        }
        shown = false
        #expect(ask(1, 0) == .unavailable)
        #expect(ask(2, o - 0.5) == .rateLimited)
        #expect(asked.count == 2)
        shown = true
        #expect(ask(3, o) == .displayed)
        #expect(ask(4, o + o - 0.5) == .rateLimited)
        #expect(ask(5, o + o) == .displayed)
        #expect(asked.count == 4)
    }

    // F-P2-1 (review of P2): the reviewer's hints and names, from a peer's own Bonjour record.
    @Test func labelsArePlainAndTellSameNamesApartByHexOnly() {
        let peers = [Peer(id: "1", name: "alpha", hint: "\u{202E}abc", candidates: []),
                     Peer(id: "2", name: "alpha", hint: "\nx\u{2028}", candidates: []),
                     Peer(id: "3", name: "alpha\u{202E}", hint: "0123456789ABCDEF", candidates: []),
                     Peer(id: "4", name: "beta", hint: "FFFF0000", candidates: [])]
        let labels = NudgeService.labels(for: peers)
        #expect(labels["1"] == "alpha・abc")
        #expect(labels["2"] == "alpha・?")
        // Same once made plain: told apart too.
        #expect(labels["3"] == "alpha・0123")
        #expect(labels["4"] == "beta")
        for label in labels.values {
            #expect(CubiChannel.plain(label, limit: CubiChannel.nameLimit + 5, fallback: "") == label)
        }
    }

    // F-P2-2: the reviewer's longest record: a 63-byte id (a DNS label's most), a name of 62 emoji
    // (248 bytes, what TXT holds), a hint of "a" and 125 combining marks, 50 of them; and ids too long.
    @Test func stateNeverPassesCubisLineLimit() {
        let name = String(repeating: "🙂", count: 62)
        let hint = "a" + String(repeating: "\u{0301}", count: 125)
        let peers = (0..<NudgeService.peerLimit).map {
            Peer(id: String(repeating: "i", count: 61) + String(format: "%02d", $0), name: name, hint: hint, candidates: [])
        }
        #expect(peers.allSatisfy { $0.id.utf8.count == 63 })
        let data = HelperApp.stateData(name: "alpha", peers: peers)
        #expect(CubiChannel.stateSize(data) <= CubiChannel.lineLimit)
        #expect((data["peers"] as? [[String: String]])?.isEmpty == false)
        let tooLong = Peer(id: String(repeating: "i", count: NudgeService.idLimit + 1), name: "x", hint: "", candidates: [])
        #expect(NudgeService.list([tooLong]).isEmpty)
        // Longer than a TXT record can carry (an emoji family is 5 scalars, 18 bytes; plain keeps 32
        // of them): the line would pass the limit, so peers come off the end until it fits.
        let heavy = (0..<NudgeService.peerLimit).map {
            Peer(id: String(repeating: "i", count: 61) + String(format: "%02d", $0), name: String(repeating: "👨‍👩‍👧", count: 40), hint: "", candidates: [])
        }
        let untrimmed: [String: Any] = ["needsName": false, "name": "alpha", "peers": NudgeService.list(heavy)]
        #expect(CubiChannel.stateSize(untrimmed) > CubiChannel.lineLimit)
        let trimmed = HelperApp.stateData(name: "alpha", peers: heavy)
        let kept = (trimmed["peers"] as? [[String: String]])?.count ?? 0
        #expect(CubiChannel.stateSize(trimmed) <= CubiChannel.lineLimit)
        #expect(kept > 0 && kept < NudgeService.peerLimit)
        // An ordinary neighbourhood is listed whole.
        let ordinary = (0..<NudgeService.peerLimit).map { Peer(id: "LANNudge-\($0)", name: String(repeating: "名", count: 40), hint: "ABCD\($0)", candidates: []) }
        #expect((HelperApp.stateData(name: "alpha", peers: ordinary)["peers"] as? [[String: String]])?.count == NudgeService.peerLimit)
    }
}
