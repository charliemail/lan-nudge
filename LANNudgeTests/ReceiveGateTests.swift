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

    @Test func busyQueuesOnlyForSendersThatCanReadQueued() {
        var gate = ReceiveGate()
        var queue = NudgeQueue<Int>()
        _ = gate.decide(sender: alice, id: UUID(), now: t0, muted: false, busy: false) { true }
        let new = gate.decide(sender: bob, id: UUID(), now: t0.addingTimeInterval(1), muted: false, busy: true,
                              acceptsQueued: true, enqueue: { queue.add(1, from: bob) }) { true }
        let old = gate.decide(sender: "C", id: UUID(), now: t0.addingTimeInterval(1), muted: false, busy: true,
                              acceptsQueued: false, enqueue: { queue.add(2, from: "C") }) { true }
        #expect([new, old] == [.queued, .rateLimited])
        #expect(queue.count == 1)
    }

    @Test func queuedCountsTowardSenderIntervalAndResendStaysQueued() {
        var gate = ReceiveGate()
        let id = UUID()
        #expect(gate.decide(sender: bob, id: id, now: t0, muted: false, busy: true, acceptsQueued: true, enqueue: { true }) { true } == .queued)
        #expect(gate.decide(sender: bob, id: id, now: t0.addingTimeInterval(1), muted: false, busy: false) { true } == .queued)
        #expect(gate.decide(sender: bob, id: UUID(), now: t0.addingTimeInterval(2), muted: false, busy: false) { true } == .rateLimited)
    }

    @Test func fullQueueTurnsAway() {
        var gate = ReceiveGate()
        #expect(gate.decide(sender: bob, id: UUID(), now: t0, muted: false, busy: true, acceptsQueued: true, enqueue: { false }) { true } == .rateLimited)
    }

    @Test func queueIsBoundedFifoWithOnePerSender() {
        var queue = NudgeQueue<String>()
        let added = [("a1", "a"), ("a2", "a"), ("b", "b"), ("c", "c"), ("d", "d"), ("e", "e"), ("f", "f")]
            .map { queue.add($0.0, from: $0.1) }
        #expect(added == [true, false, true, true, true, true, false])
        let first = queue.next()
        let readded = queue.add("a2", from: "a")
        let second = queue.next()
        #expect(first == "a1" && readded && second == "b")
        queue.removeAll()
        let empty = queue.next()
        #expect(empty == nil)
    }

    @Test func stickyLimitsAllowSeveralPerSender() {
        var queue = NudgeQueue<String>()
        queue.capacity = 4
        queue.perSender = 2
        let added = [("a1", "a"), ("a2", "a"), ("a3", "a"), ("b1", "b"), ("b2", "b"), ("c1", "c")]
            .map { queue.add($0.0, from: $0.1) }
        #expect(added == [true, true, false, true, true, false])
        #expect(queue.count == 4)
    }
}

struct SentLogTests {
    @Test func receiptCountsOnlyFromTheDeviceItWentToAndOnlyOnce() {
        var log = SentLog()
        let id = UUID()
        log.remember(id, hint: "AAAA1111", name: "C2")
        #expect(log.claim(id, from: "BBBB2222FFFF") == nil)
        #expect(log.claim(UUID(), from: "AAAA1111FFFF") == nil)
        #expect(log.claim(id, from: "AAAA1111FFFF") == "C2")
        #expect(log.claim(id, from: "AAAA1111FFFF") == nil)
    }

    @Test func forgetsTheOldestPastCapacity() {
        var log = SentLog()
        log.capacity = 2
        let ids = [UUID(), UUID(), UUID()]
        ids.forEach { log.remember($0, hint: "A", name: "n") }
        #expect(log.claim(ids[0], from: "A") == nil)
        #expect(log.claim(ids[2], from: "A") == "n")
    }
}

struct ComposeEditTests {
    @Test func typedReturnSendsWithoutTheLineBreak() {
        #expect(ComposeView.edit(old: "來開會", new: "來開會\n") == ("來開會", true))
        #expect(ComposeView.edit(old: "來開會", new: "來\n開會") == ("來開會", true))
    }

    @Test func spacesStayAndPastedLineBreaksBecomeSpaces() {
        #expect(ComposeView.edit(old: "a", new: "a ") == ("a ", false))
        #expect(ComposeView.edit(old: "", new: "第一行\n第二行") == ("第一行 第二行", false))
    }

    @Test func lengthIsCapped() {
        let long = String(repeating: "字", count: 70)
        #expect(ComposeView.edit(old: "", new: long).text.count == NudgeMessage.maxLength)
    }
}

struct DisplayTimeTests {
    @Test func automatic() {
        #expect(AppModel.durations(custom: nil, message: nil, animation: 1.4) == (1.4, 1.4))
        #expect(AppModel.durations(custom: nil, message: "短", animation: 1.4) == (1.4, 3))
        #expect(AppModel.durations(custom: nil, message: String(repeating: "字", count: 30), animation: 2) == (2, 6))
        #expect(AppModel.durations(custom: nil, message: String(repeating: "字", count: 60), animation: 2) == (2, 8))
    }

    @Test func customAppliesToEverythingAndIsClamped() {
        #expect(AppModel.durations(custom: 10, message: nil, animation: 1.4) == (10, 10))
        #expect(AppModel.durations(custom: 10, message: "嗨", animation: 2) == (10, 10))
        #expect(AppModel.durations(custom: 1, message: nil, animation: 2) == (2, 2))
        #expect(AppModel.durations(custom: 99, message: nil, animation: 2) == (15, 15))
    }
}
