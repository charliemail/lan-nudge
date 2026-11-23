import Foundation
import Network
import Security
import Testing
@testable import LANNudge

/// End-to-end over loopback with real Keychain identities: receiver identity check and the
/// address race. Creates two throwaway identities in the login keychain and deletes them after.
@MainActor
@Suite(.serialized)
struct MutualTLSTests {
    @Test func receiverIdentityCheckAndAddressRace() async throws {
        let labels = ["LAN Nudge Test A", "LAN Nudge Test B"]
        defer { labels.forEach(Self.deleteIdentity) }
        labels.forEach(Self.deleteIdentity)
        let a = try LocalIdentity.loadOrCreate(label: labels[0])
        let b = try LocalIdentity.loadOrCreate(label: labels[1])
        #expect(a.fingerprint != b.fingerprint)
        #expect(try LocalIdentity.loadOrCreate(label: labels[0]).fingerprint == a.fingerprint)

        let receiver = PeerNetwork(identity: b, displayName: "B", advertise: false)
        var seenSender: String?
        receiver.onRequest = { sender, check in
            seenSender = sender
            return check.id == nil ? nil : .displayed
        }
        receiver.startListener()
        var port: UInt16?
        for _ in 0..<50 where port == nil {
            try await Task.sleep(for: .milliseconds(20))
            port = receiver.listeningPort
        }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: try #require(port))!)
        let sender = PeerNetwork(identity: a, displayName: "A", advertise: false)
        func peer(hint fingerprint: String, _ candidates: [NWEndpoint]) -> Peer {
            Peer(id: "B", name: "B", hint: Fingerprint.hint(fingerprint), candidates: candidates)
        }

        // No pairing: the receiver accepts any client but learns its certificate fingerprint.
        #expect(await sender.send(.shake, to: peer(hint: b.fingerprint, [endpoint])) == .ack(.displayed))
        #expect(seenSender == a.fingerprint)

        // A Bonjour record claiming another device's hint can't redirect the nudge.
        seenSender = nil
        #expect(await sender.send(.shake, to: peer(hint: a.fingerprint, [endpoint])) == .noAck)
        #expect(seenSender == nil)

        // TEST-NET-1 is unroutable: the attempt hangs like a LAN address behind a full-tunnel VPN.
        let blackhole = NWEndpoint.hostPort(host: "192.0.2.1", port: 9)
        let started = ContinuousClock.now
        #expect(await sender.send(.cartoonShock, to: peer(hint: b.fingerprint, [blackhole, endpoint])) == .ack(.displayed))
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    private static func deleteIdentity(_ label: String) {
        SecItemDelete([kSecClass: kSecClassCertificate, kSecAttrLabel: label] as CFDictionary)
        SecItemDelete([kSecClass: kSecClassKey, kSecAttrLabel: label] as CFDictionary)
    }
}
