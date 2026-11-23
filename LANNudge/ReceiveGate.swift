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
    private var lastDisplayed: [String: Date] = [:]

    /// `present` is only called when every rule passes; it returns false when nothing could be shown
    /// (display asleep, locked, overlay busy) and the request is answered `unavailable`.
    mutating func decide(sender: String, id: UUID, now: Date, muted: Bool, busy: Bool,
                         present: () -> Bool) -> AckStatus {
        prune(now: now)
        let key = Key(sender: sender, id: id)
        if let previous = results[key] { return previous }

        let status: AckStatus
        if muted {
            status = .muted
        } else if let last = lastDisplayed[sender], now.timeIntervalSince(last) < perSenderInterval {
            status = .rateLimited
        } else if busy {
            status = .rateLimited
        } else if present() {
            status = .displayed
            lastDisplayed[sender] = now
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
