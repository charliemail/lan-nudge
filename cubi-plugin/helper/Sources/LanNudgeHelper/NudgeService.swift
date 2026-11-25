import AppKit
import Foundation

/// LAN Nudge over the app's own PeerNetwork, with Cubi drawing what the app's overlay drew: a
/// request that passes the app's ReceiveGate becomes a `present`, and Cubi's answer decides the ack.
/// While one is on screen, others wait in the app's NudgeQueue and follow it, as in the app; while
/// Cubi shows another plugin's overlay, the line waits and is tried again.
@MainActor
final class NudgeService {
    /// How long one stays up without a message (Cubi's overlay). After Cubi refused one (screen
    /// locked, say), others in this time are answered rate-limited without asking, so `present`
    /// lines never come faster than Cubi takes them.
    nonisolated static let overlaySeconds: TimeInterval = 2
    /// The app's gap before the next queued one.
    static let queueGap: TimeInterval = 0.3
    /// Cubi busy with another overlay: try the line again this much later, this many times.
    static let busyRetry: TimeInterval = 2
    static let busyRetries = 5
    /// At most this many peers are listed, and none whose id (a Bonjour service name) is longer.
    static let peerLimit = 50
    static let idLimit = 64

    struct Pending {
        let effect: Effect
        let from: String
        let message: String?
        /// The real window was tried for this one already (or is not to be): never again, however
        /// often Cubi is busy; Cubi shakes its own Cubi instead.
        var windowTried = false
    }

    private let network: PeerNetwork
    private let present: (_ effect: String, _ from: String, _ message: String?, _ seconds: TimeInterval, _ windowShaken: Bool) -> CubiChannel.Presented
    /// The app's WindowShaker on the front window, unless Reduce Motion is on, as the app's overlay
    /// does; true when it started shaking. Tests put their own in.
    private let shakeWindow: () -> Bool
    private let peersChanged: () -> Void
    /// Runs the closure after the delay; tests run it at will.
    private let after: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private var gate = ReceiveGate()
    private var queue = NudgeQueue<Pending>()
    /// One of ours on screen; cleared by its timer, which then shows the next (the app's flag).
    private var showing = false
    /// Cubi answered busy; cleared by the retry timer.
    private var cubiBusy = false
    private var busyTries = 0
    /// The head of the line, taken out and waiting for Cubi to be free.
    private var retrying: Pending?
    private var refusedAt: Date?
    private(set) var muted = false
    private(set) var peers: [Peer] = []

    init(network: PeerNetwork, present: @escaping (String, String, String?, TimeInterval, Bool) -> CubiChannel.Presented,
         peersChanged: @escaping () -> Void,
         shakeWindow: @escaping () -> Bool = { NudgeService.mayShakeWindow() && WindowShaker.shakeFrontWindow() },
         after: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = NudgeService.sleepThen) {
        self.network = network
        self.present = present
        self.shakeWindow = shakeWindow
        self.peersChanged = peersChanged
        self.after = after
        network.onRequest = { [weak self] in self?.receive(from: $0, $1) }
        network.onPeersChanged = { [weak self] in self?.setPeers($0) }
    }

    /// Not with Reduce Motion (as the app's overlay), nor while the screen is locked or the main display
    /// asleep: a window shaking with no Cubi to see is worse than none. Cubi answers those unavailable.
    static func mayShakeWindow() -> Bool {
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        return !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !locked && CGDisplayIsAsleep(CGMainDisplayID()) == 0
    }

    nonisolated static func sleepThen(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            work()
        }
    }

    func setPeers(_ list: [Peer]) {
        peers = list.sorted { $0.name < $1.name }
        peersChanged()
    }

    func setDisplayName(_ name: String) { network.setDisplayName(name) }

    /// As the app's 暫停接收: every request is answered muted, and the queue is dropped.
    func setMuted(_ on: Bool) {
        muted = on
        if on { dropLine() }
    }

    var waiting: Int { queue.count + (retrying == nil ? 0 : 1) }

    private func dropLine() {
        queue.removeAll()
        retrying = nil
        busyTries = 0
    }

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

    /// The app's automatic display time: the animation alone, or with a message 3 s and 1 s per
    /// 10 characters, at most 8 s, so it can be read (AppModel.durations, v0.4.0).
    nonisolated static func displaySeconds(message: String?) -> TimeInterval {
        guard let message else { return overlaySeconds }
        return max(overlaySeconds, min(3 + Double(message.count / 10), 8))
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
        case .valid(let id, let effect, let message, let acceptsQueued):
            // The name comes from the sender's own Bonjour record and can be spoofed, as in the app.
            let name = peers.first { sender.hasPrefix($0.hint) }.flatMap { Self.labels(for: peers)[$0.id] }
                ?? "未知裝置（\(CubiChannel.plain(String(sender.prefix(4)), limit: 4, fallback: "?"))）"
            let refused = refusedAt.map { now.timeIntervalSince($0) < Self.overlaySeconds } ?? false
            let waitable = showing || cubiBusy
            return gate.decide(sender: sender, id: id, now: now, muted: muted, busy: waitable || refused,
                               acceptsQueued: acceptsQueued,
                               // Only behind something that will end; after a refusal there is nothing to wait for.
                               enqueue: { waitable && queue.add(Pending(effect: effect, from: name, message: message), from: sender) }) {
                // Cubi busy with another plugin's overlay: this one is answered not shown, and the
                // ones after it wait for the retry.
                show(Pending(effect: effect, from: name, message: message), now: now) == .shown
            }
        }
    }

    /// The app's 預覽動畫 from the panel: shown as one received is, so what arrives meanwhile waits
    /// behind it as it would behind any other.
    func preview(_ effect: Effect, from name: String, now: Date = .now) -> CubiChannel.Presented {
        // Not the real window: the front one is most likely the panel the preview was pressed in.
        show(Pending(effect: effect, from: name, message: nil, windowTried: true), now: now)
    }

    /// Asks Cubi to show it for its display time. Shown: the next follows when that time and the
    /// gap are up. Busy: tried again later. Unavailable: others are turned away for a while.
    private func show(_ item: Pending, now: Date) -> CubiChannel.Presented {
        let seconds = Self.displaySeconds(message: item.message)
        // The app's WindowShaker checks and starts in one call, so the window goes first; Cubi is
        // told whether it did, and shakes its own Cubi when not.
        let shaken = item.effect == .shake && !item.windowTried && shakeWindow()
        let answer = present(Self.cubiEffect(item.effect), item.from, item.message, seconds, shaken)
        switch answer {
        case .shown:
            showing = true
            busyTries = 0
            after(seconds + Self.queueGap) { [weak self] in
                self?.showing = false
                self?.showNext()
            }
        case .busy:
            cubiBusy = true
            after(Self.busyRetry) { [weak self] in
                self?.cubiBusy = false
                self?.showNext()
            }
        case .unavailable:
            refusedAt = now
        }
        return answer
    }

    /// As the app: the next in line, unless receiving is paused. Cubi busy keeps the line, up to
    /// `busyRetries` tries; one Cubi cannot show (the screen went to sleep or locked) ends it,
    /// stale by the time the user is back.
    func showNext(now: Date = .now) {
        guard !muted, !showing, !cubiBusy, let next = retrying ?? queue.next() else { return }
        retrying = nil
        switch show(next, now: now) {
        case .shown:
            break
        case .busy:
            busyTries += 1
            var again = next
            again.windowTried = true
            if busyTries < Self.busyRetries { retrying = again } else { dropLine() }
        case .unavailable:
            dropLine()
        }
    }

    // MARK: - Sending

    /// `call` action `send`, args `peer` (an id from the last `state`), `effect` (knock, zap, shake)
    /// and an optional `message`, cleaned as the app cleans it.
    func send(peerID: String, effect name: String, message: String? = nil) async -> (ok: Bool, out: [String: Any]) {
        guard let effect = Self.effect(cubi: name) else { return (false, ["error": "effect 只能是 knock、zap、shake"]) }
        guard let peer = peers.first(where: { $0.id == peerID }) else { return (false, ["error": "附近沒有這台裝置"]) }
        let outcome = await network.send(effect, message: NudgeMessage.sanitize(message), to: peer)
        return (outcome == .ack(.displayed) || outcome == .ack(.queued), ["result": outcome.message])
    }
}
