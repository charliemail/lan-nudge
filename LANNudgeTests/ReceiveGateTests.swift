import Foundation
import Testing
@testable import LANNudge

struct ReceiveGateTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let alice = "A"
    let bob = "B"

    @Test func resentEventReturnsOriginalResultAndPlaysOnce() {
        var gate = ReceiveGate()
        var plays = 0
        let id = UUID()
        let first = gate.decide(sender: alice, id: id, now: t0, muted: false, busy: false) { plays += 1; return true }
        let again = gate.decide(sender: alice, id: id, now: t0.addingTimeInterval(1), muted: true, busy: true) { plays += 1; return true }
        #expect(first == .displayed)
        #expect(again == .displayed)
        #expect(plays == 1)
    }

    @Test func sameIDFromDifferentSendersIsNotDeduplicated() {
        var gate = ReceiveGate()
        let id = UUID()
        _ = gate.decide(sender: alice, id: id, now: t0, muted: false, busy: false) { true }
        #expect(gate.decide(sender: bob, id: id, now: t0.addingTimeInterval(1), muted: false, busy: false) { true } == .displayed)
    }

    /// Two requests arriving together are serialized by the caller; the second must be limited.
    @Test func secondEventFromSameSenderWithinIntervalIsRateLimited() {
        var gate = ReceiveGate()
        var plays = 0
        let a = gate.decide(sender: alice, id: UUID(), now: t0, muted: false, busy: false) { plays += 1; return true }
        let b = gate.decide(sender: alice, id: UUID(), now: t0.addingTimeInterval(0.01), muted: false, busy: false) { plays += 1; return true }
        #expect([a, b] == [.displayed, .rateLimited])
        #expect(plays == 1)
        #expect(gate.decide(sender: alice, id: UUID(), now: t0.addingTimeInterval(5), muted: false, busy: false) { true } == .displayed)
    }

    @Test func otherSenderIsLimitedWhileOverlayBusy() {
        var gate = ReceiveGate()
        _ = gate.decide(sender: alice, id: UUID(), now: t0, muted: false, busy: false) { true }
        #expect(gate.decide(sender: bob, id: UUID(), now: t0.addingTimeInterval(0.5), muted: false, busy: true) { true } == .rateLimited)
    }

    @Test func mutedNeverPresentsAndDoesNotStartInterval() {
        var gate = ReceiveGate()
        var plays = 0
        #expect(gate.decide(sender: alice, id: UUID(), now: t0, muted: true, busy: false) { plays += 1; return true } == .muted)
        #expect(plays == 0)
        #expect(gate.decide(sender: alice, id: UUID(), now: t0.addingTimeInterval(1), muted: false, busy: false) { true } == .displayed)
    }

    @Test func failedPresentationIsUnavailableAndDoesNotStartInterval() {
        var gate = ReceiveGate()
        #expect(gate.decide(sender: alice, id: UUID(), now: t0, muted: false, busy: false) { false } == .unavailable)
        #expect(gate.decide(sender: alice, id: UUID(), now: t0.addingTimeInterval(1), muted: false, busy: false) { true } == .displayed)
    }

    @Test func resultExpiresAfterTTL() {
        var gate = ReceiveGate()
        let id = UUID()
        _ = gate.decide(sender: alice, id: id, now: t0, muted: true, busy: false) { true }
        #expect(gate.decide(sender: alice, id: id, now: t0.addingTimeInterval(60), muted: false, busy: false) { true } == .displayed)
    }

    @Test func cacheIsBounded() {
        var gate = ReceiveGate()
        gate.maxResults = 3
        let first = UUID()
        _ = gate.decide(sender: alice, id: first, now: t0, muted: true, busy: false) { true }
        for i in 1...3 {
            _ = gate.decide(sender: alice, id: UUID(), now: t0.addingTimeInterval(Double(i)), muted: true, busy: false) { true }
        }
        // `first` was evicted, so it is decided again instead of replaying `.muted`.
        #expect(gate.decide(sender: alice, id: first, now: t0.addingTimeInterval(4), muted: false, busy: false) { true } == .displayed)
    }
}
