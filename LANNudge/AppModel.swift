import AppKit
import CoreGraphics
import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class AppModel {
    /// `-instance B` runs a second copy on the same Mac with its own identity and settings,
    /// so nudging can be exercised without a second machine.
    let instance = UserDefaults.standard.string(forKey: "instance")

    private(set) var displayName: String
    var muted: Bool {
        didSet { defaults.set(muted, forKey: "muted"); if muted { queue.removeAll() } }
    }
    var showMessages: Bool { didSet { defaults.set(showMessages, forKey: "showMessages") } }
    /// nil = automatic (see `durations`); otherwise every nudge stays this long.
    var customDisplaySeconds: Int? {
        didSet {
            if let s = customDisplaySeconds, !Self.displayRange.contains(s) {
                customDisplaySeconds = min(max(s, Self.displayRange.lowerBound), Self.displayRange.upperBound)
            }
            defaults.set(customDisplaySeconds, forKey: "customDisplaySeconds")
        }
    }
    nonisolated static let displayRange = 2...15
    /// Nudges with a message stay on screen until 確認 is clicked instead of timing out (ones without
    /// time out as usual); ones that arrive meanwhile, or while the screen is locked or asleep, wait
    /// in the queue (limits below).
    var stickyNudges: Bool { didSet { defaults.set(stickyNudges, forKey: "stickyNudges") } }
    var queueLimit: Int {
        didSet { queueLimit = Self.queueLimitRange.clamp(queueLimit); defaults.set(queueLimit, forKey: "queueLimit") }
    }
    var perSenderLimit: Int {
        didSet { perSenderLimit = Self.perSenderRange.clamp(perSenderLimit); defaults.set(perSenderLimit, forKey: "perSenderLimit") }
    }
    nonisolated static let queueLimitRange = 1...20
    nonisolated static let perSenderRange = 1...5
    nonisolated static let defaultQueueLimit = 10
    nonisolated static let defaultPerSenderLimit = 3
    /// 確認 tells the sender the nudge was read (sticky mode only).
    var sendReadReceipts: Bool { didSet { defaults.set(sendReadReceipts, forKey: "sendReadReceipts") } }
    /// Recently received messages (nudges without one aren't kept), newest first, in memory only:
    /// messages aren't written to disk.
    private(set) var history: [Received] = []
    var historyLimit: Int {
        didSet {
            historyLimit = Self.historyRange.clamp(historyLimit)
            defaults.set(historyLimit, forKey: "historyLimit")
            history = Array(history.prefix(historyLimit))
        }
    }
    nonisolated static let historyRange = 1...50
    nonisolated static let defaultHistoryLimit = 10
    /// Fingerprint hint → name when blocked. Blocked senders are answered `muted`, as if paused.
    private(set) var blocked: [String: String]
    /// Peer the "附帶訊息…" window sends to.
    var composeTarget: Peer?
    /// SwiftUI's window opener, for AppKit callers (the desktop pet, a relaunch). Set by the menu bar
    /// icon: the one view that exists for the app's whole life, even when crowded off the menu bar.
    @ObservationIgnored var openWindow: OpenWindowAction?
    private(set) var peers: [Peer] = []
    private(set) var networkProblem: String?
    private(set) var identityError: String?
    private(set) var lastResult: String?
    private(set) var scanning = false
    let pet: DesktopPet

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var identity: LocalIdentity?
    @ObservationIgnored private var network: PeerNetwork?
    @ObservationIgnored private var gate = ReceiveGate()
    @ObservationIgnored private var screensAsleep = false
    @ObservationIgnored private var sent = SentLog()
    /// Saved as JSON; colleagues' names and addresses stay on this Mac only.
    @ObservationIgnored private var known: KnownPeers
    @ObservationIgnored private var bonjourPeers: [Peer] = []
    /// Remembered peers that answered a hello, by hint; listed while Bonjour can't see them.
    @ObservationIgnored private var remembered: [String: Peer] = [:]
    @ObservationIgnored private var probing: Set<String> = []
    /// The sticky nudge on screen, for its read receipt.
    @ObservationIgnored private var onScreen: Receipt?
    private var queue = NudgeQueue<Pending>()
    /// True from a nudge appearing until its display time (plus a short gap) has passed, or until
    /// 確認 is clicked.
    private var showing = false

    /// The nudge on screen plus the ones waiting behind it; the overlay and pet read it live.
    var unread: Int { (showing ? 1 : 0) + queue.count }

    private struct Pending {
        let effect: Effect
        let sender: String
        let message: String?
        let receipt: Receipt
    }

    /// Which request to confirm as read, and to which device (its full TLS fingerprint).
    struct Receipt {
        let id: UUID
        let sender: String
    }

    struct Received: Identifiable {
        let id = UUID()
        let requestID: UUID
        let date: Date
        let sender: String
        let message: String
        /// Arrived while receiving was paused, so it wasn't shown.
        let paused: Bool

        var line: String {
            "\(date.formatted(date: .omitted, time: .shortened))　\(sender)：\(message)" + (paused ? "（暫停中）" : "")
        }
    }

    init() {
        defaults = instance.flatMap { UserDefaults(suiteName: "dev.lannudge.instance.\($0)") } ?? .standard
        displayName = defaults.string(forKey: "displayName") ?? ""
        muted = defaults.bool(forKey: "muted")
        showMessages = defaults.object(forKey: "showMessages") as? Bool ?? true
        customDisplaySeconds = defaults.object(forKey: "customDisplaySeconds") as? Int
        stickyNudges = defaults.bool(forKey: "stickyNudges")
        queueLimit = defaults.object(forKey: "queueLimit") as? Int ?? Self.defaultQueueLimit
        perSenderLimit = defaults.object(forKey: "perSenderLimit") as? Int ?? Self.defaultPerSenderLimit
        sendReadReceipts = defaults.object(forKey: "sendReadReceipts") as? Bool ?? true
        historyLimit = defaults.object(forKey: "historyLimit") as? Int ?? Self.defaultHistoryLimit
        blocked = defaults.dictionary(forKey: "blocked") as? [String: String] ?? [:]
        known = defaults.data(forKey: "knownPeers").flatMap { try? JSONDecoder().decode(KnownPeers.self, from: $0) } ?? KnownPeers()
        pet = DesktopPet(defaults: defaults, instance: instance)
        pet.onDoubleClick = { [weak self] in self?.bringUp("panel") }

        do {
            identity = try LocalIdentity.loadOrCreate(label: "LAN Nudge Identity" + (instance.map { " \($0)" } ?? ""))
        } catch {
            identityError = error.localizedDescription
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = true; self?.dropStaleQueue() }
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dropStaleQueue() }
        }
        // Sticky mode keeps what arrived while away and shows it once the user is back.
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showNextIfIdle() }
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = false; self?.showNextIfIdle() }
        }
        startNetworkIfReady()
    }

    func isBlocked(_ peer: Peer) -> Bool { blocked[peer.hint] != nil }

    func setBlocked(_ on: Bool, hint: String, name: String) {
        blocked[hint] = on ? name : nil
        defaults.set(blocked, forKey: "blocked")
    }

    func clearHistory() { history.removeAll() }

    /// A menu bar app isn't the active app when its menu is used, and NSApp.activate() is only a
    /// request macOS may turn down, so the window would open (or stay) behind the current app's
    /// windows. Ordering it front directly works either way.
    func bringUp(_ id: String) {
        openWindow?(id: id)
        DispatchQueue.main.async {
            NSApp.activate()
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(id) == true }) else { return }
            window.orderFrontRegardless()
            window.makeKey()
        }
    }

    /// The desktop pet's read-receipt GIF, or a notice at the top right when the pet can't show it.
    func showRead(from name: String) {
        if !pet.read("\(name) 已讀") { OverlayController.shared.toast("\(name) 已讀") }
    }

    var needsSetup: Bool { displayName.isEmpty }

    func setDisplayName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        displayName = trimmed
        defaults.set(trimmed, forKey: "displayName")
        network?.setDisplayName(trimmed)
        startNetworkIfReady()
    }

    /// Name shown in lists; adds the fingerprint tail only when two nearby names collide.
    func label(for peer: Peer) -> String {
        peers.filter { $0.name == peer.name }.count > 1 ? "\(peer.name)・\(peer.hint.prefix(4))" : peer.name
    }

    func nudge(_ peer: Peer, with effect: Effect, message: String? = nil) {
        guard let network else { return }
        let name = label(for: peer)
        let id = UUID()
        lastResult = "\(name)：傳送中…"
        Task {
            let outcome = await network.send(effect, message: NudgeMessage.sanitize(message), id: id, to: peer)
            lastResult = "\(name)：\(outcome.message)"
            if outcome == .ack(.displayed) || outcome == .ack(.queued) { sent.remember(id, hint: peer.hint, name: name) }
        }
    }

    /// While the desktop pet is visible it is the only reaction to every effect (no overlay, no window
    /// shake). Hidden pet (full-screen Space, turned off) falls back to the effect's own overlay.
    /// When the display time is up (sticky mode: when 確認 is clicked), the next queued nudge follows.
    @discardableResult
    func present(_ effect: Effect, from sender: String, message: String? = nil, receipt: Receipt? = nil) -> Bool {
        guard !showing else { return false }
        let petLoop = pet.shockLoop
        let time = Self.durations(custom: customDisplaySeconds, message: message,
                                  animation: petLoop ?? OverlayController.defaultDuration)
        let sticky = stickyNudges && message != nil
        let stayFor: Double? = sticky ? nil : time.total
        var confirm: (@MainActor () -> Void)?
        if sticky { confirm = { [weak self] in self?.confirm() } }
        let card = NudgeCard(sender: sender, message: message, unread: { [weak self] in self?.unread ?? 0 }, confirm: confirm)
        let shown = petLoop != nil
            ? pet.shock(card, animateFor: time.animation, showFor: stayFor)
            : OverlayController.shared.show(effect, card: card, animateFor: time.animation, duration: stayFor)
        guard shown else { return false }
        showing = true
        onScreen = receipt
        if let stayFor {
            Task {
                try? await Task.sleep(for: .seconds(stayFor + 0.3))
                showing = false
                showNext()
            }
        }
        return true
    }

    /// 確認 on a sticky nudge: clear it and show the next one.
    func confirm() {
        guard showing else { return }
        pet.dismiss()
        OverlayController.shared.hide()
        showing = false
        if sendReadReceipts, let receipt = onScreen, let network,
           let peer = peers.first(where: { receipt.sender.hasPrefix($0.hint) }) {
            Task { _ = await network.sendReadReceipt(for: receipt.id, to: peer) }
        }
        onScreen = nil
        showNext()
    }

    private func showNext() {
        guard !muted else { return queue.removeAll() }
        guard !screensAsleep, !Self.screenLocked() else { return dropStaleQueue() }
        while let next = queue.next() {
            if present(next.effect, from: next.sender, message: next.message, receipt: next.receipt) { return }
        }
    }

    private func showNextIfIdle() {
        if !showing { showNext() }
    }

    /// Timed nudges queued while the user is away are stale by the time they are back; sticky ones
    /// are what the mode is for.
    private func dropStaleQueue() {
        if !stickyNudges { queue.removeAll() }
    }

    /// Automatic: the animation alone, or with a message 3 s + 1 s per 10 characters (max 8 s) so it
    /// can be read. Custom: everything stays that long and the animation repeats.
    nonisolated static func durations(custom: Int?, message: String?, animation: Double) -> (animation: Double, total: Double) {
        if let custom {
            let seconds = Double(min(max(custom, displayRange.lowerBound), displayRange.upperBound))
            return (seconds, seconds)
        }
        guard let message else { return (animation, animation) }
        return (animation, max(animation, min(3 + Double(message.count / 10), 8)))
    }

    private func receive(from sender: String, host: String?, _ check: RequestCheck) -> AckStatus? {
        switch check {
        case .unreadable:
            return nil
        case .hello(_, let port, let helloName):
            let hint = Fingerprint.hint(sender)
            guard let host, known.heard(from: hint, host: host, port: port, name: helloName, now: .now) else { return .invalid }
            saveKnown()
            if !bonjourPeers.contains(where: { $0.hint == hint }) { remembered[hint] = known.peer(hint) }
            updatePeers()
            return .displayed
        case .invalid:
            return .invalid
        case .read(let id):
            guard !blocked.keys.contains(where: { sender.hasPrefix($0) }), let name = sent.claim(id, from: sender) else { return .invalid }
            lastResult = "\(name)：已讀"
            if !muted { showRead(from: name) }
            return .displayed
        case .valid(let id, let effect, let message, let acceptsQueued):
            // ponytail: the name comes from the sender's own Bonjour record, so it can be spoofed;
            // accepted with the no-pairing decision.
            let name = peers.first { sender.hasPrefix($0.hint) }.map(label)
                ?? known.entries[Fingerprint.hint(sender)]?.name ?? "未知裝置（\(sender.prefix(4))）"
            let text = showMessages ? message : nil
            let away = screensAsleep || Self.screenLocked()
            queue.capacity = stickyNudges ? queueLimit : 5
            queue.perSender = stickyNudges ? perSenderLimit : 1
            let isBlocked = blocked.keys.contains(where: { sender.hasPrefix($0) })
            let receipt = Receipt(id: id, sender: sender)
            // Sticky mode: while away, nudges wait for the user instead of being turned away.
            let status = gate.decide(sender: sender, id: id, now: .now, muted: muted || isBlocked,
                                     busy: showing || (stickyNudges && away), acceptsQueued: acceptsQueued,
                                     enqueue: { queue.add(Pending(effect: effect, sender: name, message: text, receipt: receipt), from: sender) }) {
                !away && present(effect, from: name, message: text, receipt: receipt)
            }
            if let text, !isBlocked, [.displayed, .queued, .muted].contains(status), !history.contains(where: { $0.requestID == id }) {
                history.insert(Received(requestID: id, date: .now, sender: name, message: text,
                                        paused: status == .muted), at: 0)
                history = Array(history.prefix(historyLimit))
            }
            return status
        }
    }

    private static func screenLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func startNetworkIfReady() {
        // Unit tests launch the app as their host; it must not advertise the user's identity
        // alongside a copy the user is running.
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        guard network == nil, !displayName.isEmpty, !isTestHost, let identity else { return }
        let network = PeerNetwork(identity: identity, displayName: displayName)
        network.onRequest = { [weak self] in self?.receive(from: $0, host: $1, $2) }
        network.onPeersChanged = { [weak self] in self?.bonjourChanged($0) }
        network.onProblem = { [weak self] in self?.networkProblem = $0 }
        // Addresses need a moment to settle after a VPN connects.
        network.onNetworkChanged = { [weak self] in
            Task { try? await Task.sleep(for: .seconds(3)); self?.probeRemembered() }
        }
        network.start()
        self.network = network
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(300))
                guard let self else { return }
                probeRemembered()
            }
        }
    }

    // MARK: Remembered peers

    private func bonjourChanged(_ found: [Peer]) {
        let lost = Set(bonjourPeers.map(\.hint)).subtracting(found.map(\.hint))
        bonjourPeers = found
        found.forEach { known.met($0, now: .now) }
        saveKnown()
        found.forEach { remembered[$0.hint] = nil }
        updatePeers()
        // Someone who just left the Wi-Fi may still be on the VPN.
        if !lost.isEmpty { probeRemembered() }
    }

    /// Says hello to every remembered peer Bonjour can't see. An answer lists it (and tells it this
    /// Mac's current address); silence drops it until the next round.
    private func probeRemembered() {
        guard let network else { return }
        known.prune(now: .now)
        let visible = Set(bonjourPeers.map(\.hint))
        for hint in known.entries.keys where !visible.contains(hint) && !probing.contains(hint) {
            guard let peer = known.peer(hint) else { continue }
            probing.insert(hint)
            Task {
                defer { probing.remove(hint) }
                guard let outcome = await network.hello(peer) else { return }
                guard !bonjourPeers.contains(where: { $0.hint == hint }) else { return }
                if case .ack = outcome {
                    known.touch(hint, now: .now)
                    saveKnown()
                    remembered[hint] = peer
                } else {
                    remembered[hint] = nil
                }
                updatePeers()
            }
        }
    }

    /// The 掃描 VPN button: meets colleagues on the VPN that were never on the same Wi-Fi. The result
    /// also pops up at the top right, since the menu has closed by the time the scan ends.
    func scanVPN() {
        guard let network, !scanning else { return }
        scanning = true
        Task {
            var result = "沒有連上 VPN，無法掃描"
            defer {
                scanning = false
                lastResult = result
                OverlayController.shared.toast(result, seconds: 5)
            }
            guard let found = await network.scanVPN() else { return }
            for answer in found {
                let hint = Fingerprint.hint(answer.fingerprint)
                guard known.heard(from: hint, host: answer.host, port: Wire.preferredPort, name: answer.name, now: .now) else { continue }
                if !bonjourPeers.contains(where: { $0.hint == hint }) { remembered[hint] = known.peer(hint) }
            }
            saveKnown()
            updatePeers()
            result = found.isEmpty ? "VPN 上沒有找到其他 LAN Nudge" : "VPN 上找到 \(found.count) 台"
        }
    }

    private func updatePeers() {
        let visible = Set(bonjourPeers.map(\.hint))
        peers = (bonjourPeers + remembered.values.filter { !visible.contains($0.hint) }).sorted { $0.name < $1.name }
    }

    private func saveKnown() {
        defaults.set(try? JSONEncoder().encode(known), forKey: "knownPeers")
    }
}

private extension ClosedRange<Int> {
    func clamp(_ value: Int) -> Int { Swift.min(Swift.max(value, lowerBound), upperBound) }
}
