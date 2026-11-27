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
        var seenCheck: RequestCheck?
        var seenHost: String?
        receiver.onRequest = { sender, host, check in
            seenSender = sender
            seenHost = host
            seenCheck = check
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
        #expect(await sender.send(.knock, message: "來開會了", to: peer(hint: b.fingerprint, [endpoint])) == .ack(.displayed))
        guard case .valid(_, .knock, "來開會了", true)? = seenCheck else {
            Issue.record("message did not arrive: \(String(describing: seenCheck))"); return
        }
        #expect(seenSender == a.fingerprint)

        let readID = UUID()
        #expect(await sender.sendReadReceipt(for: readID, to: peer(hint: b.fingerprint, [endpoint])) == .ack(.displayed))
        #expect(seenCheck == .read(id: readID))

        // A hello carries the sender's port; its address comes from the connection.
        #expect(await sender.hello(peer(hint: b.fingerprint, [endpoint])) == nil)
        sender.startListener(port: nil)
        var senderPort: UInt16?
        for _ in 0..<50 where senderPort == nil {
            try await Task.sleep(for: .milliseconds(20))
            senderPort = sender.listeningPort
        }
        #expect(await sender.hello(peer(hint: b.fingerprint, [endpoint])) == .ack(.displayed))
        guard case .hello(_, let helloPort, "A")? = seenCheck else {
            Issue.record("hello did not arrive: \(String(describing: seenCheck))"); return
        }
        #expect(helloPort == senderPort && seenHost == "127.0.0.1")

        // A scan accepts any certificate and learns who answered.
        let answer = await sender.greet("127.0.0.1", at: try #require(port), from: try #require(senderPort))
        #expect(answer?.fingerprint == b.fingerprint && answer?.name == "B")

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
