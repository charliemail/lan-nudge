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
        var asked: [(effect: String, from: String, message: String?)] = []
        let receiverNetwork = PeerNetwork(identity: b, displayName: "B", advertise: false)
        let receiver = NudgeService(network: receiverNetwork, present: { asked.append(($0, $1, $2)); _ = $3; return .shown }, peersChanged: {})
        defer { withExtendedLifetime(receiver) {} }
        receiverNetwork.startListener()
        var port: UInt16?
        for _ in 0..<50 where port == nil {
            try await Task.sleep(for: .milliseconds(20))
            port = receiverNetwork.listeningPort
        }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: try #require(port))!)

        // The sending side, with the receiver as its one peer.
        let senderNetwork = PeerNetwork(identity: a, displayName: "A", advertise: false)
        let sender = NudgeService(network: senderNetwork, present: { _, _, _, _ in .shown }, peersChanged: {})
        sender.setPeers([Peer(id: "LANNudge-B", name: "B", hint: Fingerprint.hint(b.fingerprint), candidates: [endpoint])])

        // Over the network, with a message: drawn, triggered; the message reaches Cubi as the app
        // cleans it; an unknown sender is named by its fingerprint, as in the app.
        var result = await sender.send(peerID: "LANNudge-B", effect: "zap", message: " 開會\n囉 ")
        #expect(result.ok && result.out["result"] as? String == SendOutcome.ack(.displayed).message)
        try #require(asked.count == 1)
        #expect(asked[0].effect == "zap" && asked[0].message == "開會 囉")
        #expect(asked[0].from == "未知裝置（\(a.fingerprint.prefix(4))）")
        // Right after, the same sender: the app's per-sender limit, Cubi not asked.
        result = await sender.send(peerID: "LANNudge-B", effect: "shake")
        #expect(!result.ok && result.out["result"] as? String == SendOutcome.ack(.rateLimited).message)
        #expect(asked.count == 1)

        // A peer it does not know, or an effect Cubi does not have: refused before the network.
        #expect(await sender.send(peerID: "nobody", effect: "zap").ok == false)
        #expect(await sender.send(peerID: "LANNudge-B", effect: "cartoonShock").ok == false)
    }

    /// A service off the network whose timers run by hand, Cubi's answer set at will (`answer`),
    /// and what it was asked: effect, from, message, seconds.
    @MainActor
    private final class Rig {
        var answer = CubiChannel.Presented.shown
        var asked: [(effect: String, from: String, message: String?, seconds: TimeInterval)] = []
        var timers: [(seconds: TimeInterval, work: @MainActor () -> Void)] = []
        var service: NudgeService!
        let t0 = Date().addingTimeInterval(10)

        init(identity: LocalIdentity) {
            service = NudgeService(network: PeerNetwork(identity: identity, displayName: "B", advertise: false),
                                   present: { [unowned self] in asked.append(($0, $1, $2, $3)); return answer }, peersChanged: {},
                                   after: { [unowned self] in timers.append(($0, $1)) })
        }

        /// Senders are fingerprint-like strings, ids fresh UUIDs; acceptsQueued and the message are
        /// what a 0.4.0 sender (true, its text) and an older one (false, none) send.
        func ask(_ who: String, _ at: TimeInterval, queues: Bool = true, message: String? = nil) -> AckStatus? {
            service.receive(from: who, .valid(id: UUID(), effect: .knock, message: message, acceptsQueued: queues), now: t0.addingTimeInterval(at))
        }

        /// Runs the earliest timer and says how long it was set for; none set is a failure, not a crash.
        func fire() -> TimeInterval {
            guard !timers.isEmpty else {
                Issue.record("no timer to run")
                return -1
            }
            let timer = timers.removeFirst()
            timer.work()
            return timer.seconds
        }
    }

    // The app's v0.4.0 rules, in time.
    @Test func queueMuteAndRefusalFollowTheApp() throws {
        defer { Self.labels.forEach(Self.deleteIdentity) }
        Self.labels.forEach(Self.deleteIdentity)
        let rig = Rig(identity: try LocalIdentity.loadOrCreate(label: Self.labels[1]))
        defer { withExtendedLifetime(rig) {} }

        // One on screen: 0.4.0 senders wait in line, one each; an older sender is turned away.
        #expect(rig.ask("s1", 0) == .displayed)
        #expect(rig.ask("s2", 0.5) == .queued)
        #expect(rig.ask("s3", 0.6, queues: false) == .rateLimited)
        #expect(rig.ask("s2", 0.7) == .rateLimited)
        #expect(rig.ask("s4", 0.8, message: "abc") == .queued)
        #expect(rig.service.waiting == 2 && rig.asked.count == 1)
        // Its time and the app's gap up, the next follows, then the next, message and all.
        #expect(rig.fire() == NudgeService.overlaySeconds + NudgeService.queueGap)
        #expect(rig.asked.count == 2 && rig.service.waiting == 1)
        #expect(rig.fire() == NudgeService.overlaySeconds + NudgeService.queueGap)
        #expect(rig.asked.count == 3 && rig.asked[2].message == "abc" && rig.service.waiting == 0)
        // Cubi is told how long, the time the next one waits for (F-P2a-2).
        #expect(rig.asked[2].seconds == NudgeService.displaySeconds(message: "abc"))
        #expect(rig.fire() == NudgeService.displaySeconds(message: "abc") + NudgeService.queueGap)

        // Paused: answered muted, nothing asked, the line dropped.
        #expect(rig.ask("s5", 50) == .displayed)
        #expect(rig.ask("s6", 50.5) == .queued)
        rig.service.setMuted(true)
        #expect(rig.service.waiting == 0)
        #expect(rig.ask("s7", 51) == .muted)
        rig.service.setMuted(false)
        _ = rig.fire()

        // Cubi cannot show (the screen locked): others are turned away for a while, not queued.
        rig.answer = .unavailable
        let before = rig.asked.count
        #expect(rig.ask("s8", 100) == .unavailable)
        #expect(rig.ask("s9", 100.5) == .rateLimited)
        #expect(rig.asked.count == before + 1 && rig.service.waiting == 0)

        // One shown, two waiting, then Cubi cannot show the next: the line is dropped.
        rig.answer = .shown
        #expect(rig.ask("s10", 200) == .displayed)
        #expect(rig.ask("s11", 200.5) == .queued)
        #expect(rig.ask("s12", 200.6) == .queued)
        rig.answer = .unavailable
        _ = rig.fire()
        // s11 could not be shown, and s12 is dropped with it rather than tried later.
        #expect(rig.service.waiting == 0 && rig.timers.isEmpty)
    }

    // F-P2a-1 (review of P2a): the reviewer's timeline. s1 at 0, s2 queued at 0.5, s3 at 2.35, just
    // after the moment the old time-based check (counted from when s1 arrived) ended but before
    // s1's timer, which starts once Cubi has answered. Now s3 waits behind s2, as in the app.
    @Test func nothingJumpsTheLineBeforeTheTimerRuns() throws {
        defer { Self.labels.forEach(Self.deleteIdentity) }
        Self.labels.forEach(Self.deleteIdentity)
        let rig = Rig(identity: try LocalIdentity.loadOrCreate(label: Self.labels[1]))
        defer { withExtendedLifetime(rig) {} }
        #expect(rig.ask("AAAA", 0) == .displayed)
        #expect(rig.ask("BBBB", 0.5) == .queued)
        #expect(rig.ask("CCCC", 2.35) == .queued)
        _ = rig.fire()
        _ = rig.fire()
        #expect(rig.asked.map(\.from) == rig.asked.map(\.from).sorted() && rig.asked.count == 3)
        #expect(rig.service.waiting == 0)
    }

    // F-P2a-1: Cubi busy (another plugin's overlay) keeps the line and tries again; new ones wait
    // behind it; after `busyRetries` busy answers in a row the line is dropped.
    @Test func cubiBusyKeepsTheLineAndTriesAgain() throws {
        defer { Self.labels.forEach(Self.deleteIdentity) }
        Self.labels.forEach(Self.deleteIdentity)
        let rig = Rig(identity: try LocalIdentity.loadOrCreate(label: Self.labels[1]))
        defer { withExtendedLifetime(rig) {} }

        // Idle, Cubi busy: that one is answered not shown; those right after it wait.
        rig.answer = .busy
        #expect(rig.ask("s1", 0) == .unavailable)
        #expect(rig.ask("s2", 0.5) == .queued)
        #expect(rig.ask("s3", 0.6) == .queued)
        #expect(rig.asked.count == 1 && rig.service.waiting == 2)
        // Still busy at the retry: s2 asked, kept first in line.
        #expect(rig.fire() == NudgeService.busyRetry)
        #expect(rig.asked.count == 2 && rig.asked[1].from.contains("s2") && rig.service.waiting == 2)
        // Free: s2 again, shown, then s3.
        rig.answer = .shown
        #expect(rig.fire() == NudgeService.busyRetry)
        #expect(rig.asked.count == 3 && rig.asked[2].from.contains("s2") && rig.service.waiting == 1)
        _ = rig.fire()
        #expect(rig.asked.count == 4 && rig.asked[3].from.contains("s3") && rig.service.waiting == 0)
        _ = rig.fire()

        // Busy every time: tried busyRetries times, then the line goes.
        #expect(rig.ask("s4", 100) == .displayed)
        #expect(rig.ask("s5", 100.5) == .queued)
        rig.answer = .busy
        let before = rig.asked.count
        _ = rig.fire()
        while !rig.timers.isEmpty { _ = rig.fire() }
        #expect(rig.asked.count == before + NudgeService.busyRetries)
        #expect(rig.service.waiting == 0)
        // Busy is not a refusal: once free, the next is shown at once.
        rig.answer = .shown
        #expect(rig.ask("s6", 200) == .displayed)
    }

    @Test func aMessageStaysLongerAsInTheApp() {
        #expect(NudgeService.displaySeconds(message: nil) == NudgeService.overlaySeconds)
        #expect(NudgeService.displaySeconds(message: String(repeating: "a", count: 5)) == 3)
        #expect(NudgeService.displaySeconds(message: String(repeating: "a", count: 30)) == 6)
        #expect(NudgeService.displaySeconds(message: String(repeating: "a", count: NudgeMessage.maxLength)) == 8)
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
