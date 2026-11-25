import Foundation

/// Receiver-side decision for one verified request. Callers must serialize calls (the app runs it
/// on the main actor) so two concurrent requests can't both pass the rate limit.
struct ReceiveGate {
    struct Key: Hashable {
        let sender: String
        let id: UUID
    }

    var resultTTL: TimeInterval = 60
    var maxResults = 256
    var perSenderInterval: TimeInterval = 5

    private var results: [Key: AckStatus] = [:]
    /// Insertion order for expiry/eviction.
    private var order: [(key: Key, at: Date)] = []
    /// Accepted = displayed or queued; the per-sender interval counts from either.
    private var lastAccepted: [String: Date] = [:]

    /// `present` is only called when every rule passes and nothing is on screen; it returns false
    /// when nothing could be shown (display asleep, locked) and the request is answered `unavailable`.
    /// While busy, `enqueue` decides whether the request waits (`queued`) or is turned away.
    /// Senders that can't read `queued` (`acceptsQueued == false`) get the pre-0.4.0 `rateLimited`.
    mutating func decide(sender: String, id: UUID, now: Date, muted: Bool, busy: Bool,
                         acceptsQueued: Bool = false, enqueue: () -> Bool = { false },
                         present: () -> Bool) -> AckStatus {
        prune(now: now)
        let key = Key(sender: sender, id: id)
        if let previous = results[key] { return previous }

        let status: AckStatus
        if muted {
            status = .muted
        } else if let last = lastAccepted[sender], now.timeIntervalSince(last) < perSenderInterval {
            status = .rateLimited
        } else if busy {
            status = acceptsQueued && enqueue() ? .queued : .rateLimited
            if status == .queued { lastAccepted[sender] = now }
        } else if present() {
            status = .displayed
            lastAccepted[sender] = now
        } else {
            status = .unavailable
        }

        results[key] = status
        order.append((key, now))
        // ponytail: an entry evicted early by the cap can replay once if resent; bounded by maxResults.
        if order.count > maxResults { results[order.removeFirst().key] = nil }
        return status
    }

    private mutating func prune(now: Date) {
        while let first = order.first, now.timeIntervalSince(first.at) >= resultTTL {
            results[first.key] = nil
            order.removeFirst()
        }
    }
}

/// Nudges this copy sent that the receiver accepted, so a ReadReceipt is believed only from the
/// device the nudge went to (its TLS fingerprint) and only once.
struct SentLog {
    var capacity = 50
    private var entries: [(id: UUID, hint: String, name: String)] = []

    mutating func remember(_ id: UUID, hint: String, name: String) {
        entries.append((id, hint, name))
        if entries.count > capacity { entries.removeFirst() }
    }

    /// The receiver's name when `fingerprint` is the device `id` was sent to; nil otherwise.
    mutating func claim(_ id: UUID, from fingerprint: String) -> String? {
        guard let index = entries.firstIndex(where: { $0.id == id && fingerprint.hasPrefix($0.hint) }) else { return nil }
        return entries.remove(at: index).name
    }
}

/// Nudges waiting for the screen. Bounded, with a per-sender cap so one person can't fill it,
/// first in first out.
struct NudgeQueue<Item> {
    var capacity = 5
    var perSender = 1
    private var items: [(sender: String, item: Item)] = []

    var count: Int { items.count }

    mutating func add(_ item: Item, from sender: String) -> Bool {
        guard items.count < capacity, items.count(where: { $0.sender == sender }) < perSender else { return false }
        items.append((sender, item))
        return true
    }

    mutating func next() -> Item? { items.isEmpty ? nil : items.removeFirst().item }

    mutating func removeAll() { items.removeAll() }
}
