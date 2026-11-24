import AppKit
import CoreGraphics
import Foundation
import Observation

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
    /// Peer the "附帶訊息…" window sends to.
    var composeTarget: Peer?
    private(set) var peers: [Peer] = []
    private(set) var networkProblem: String?
    private(set) var identityError: String?
    private(set) var lastResult: String?
    let pet: DesktopPet

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var identity: LocalIdentity?
    @ObservationIgnored private var network: PeerNetwork?
    @ObservationIgnored private var gate = ReceiveGate()
    @ObservationIgnored private var screensAsleep = false
    @ObservationIgnored private var queue = NudgeQueue<Pending>()
    /// True from a nudge appearing until its display time (plus a short gap) has passed.
    @ObservationIgnored private var showing = false

    private struct Pending {
        let effect: Effect
        let sender: String
        let message: String?
    }

    init() {
        defaults = instance.flatMap { UserDefaults(suiteName: "dev.lannudge.instance.\($0)") } ?? .standard
        displayName = defaults.string(forKey: "displayName") ?? ""
        muted = defaults.bool(forKey: "muted")
        showMessages = defaults.object(forKey: "showMessages") as? Bool ?? true
        customDisplaySeconds = defaults.object(forKey: "customDisplaySeconds") as? Int
        pet = DesktopPet(defaults: defaults, instance: instance)

        do {
            identity = try LocalIdentity.loadOrCreate(label: "LAN Nudge Identity" + (instance.map { " \($0)" } ?? ""))
        } catch {
            identityError = error.localizedDescription
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = true; self?.queue.removeAll() }
        }
        // Queued nudges are stale by the time the user is back.
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.queue.removeAll() }
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = false }
        }
        startNetworkIfReady()
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
        lastResult = "\(name)：傳送中…"
        Task {
            let outcome = await network.send(effect, message: NudgeMessage.sanitize(message), to: peer)
            lastResult = "\(name)：\(outcome.message)"
        }
    }

    /// While the desktop pet is visible it is the only reaction to every effect (no overlay, no window
    /// shake). Hidden pet (full-screen Space, turned off) falls back to the effect's own overlay.
    /// When the display time is up, the next queued nudge (if any) follows.
    @discardableResult
    func present(_ effect: Effect, from sender: String, message: String? = nil) -> Bool {
        guard !showing else { return false }
        let petLoop = pet.shockLoop
        let time = Self.durations(custom: customDisplaySeconds, message: message,
                                  animation: petLoop ?? OverlayController.defaultDuration)
        let shown = petLoop != nil
            ? pet.shock(.init(sender: sender, message: message, waiting: queue.count),
                        animateFor: time.animation, showFor: time.total)
            : OverlayController.shared.show(effect, from: sender, message: message, waiting: queue.count, duration: time.total)
        guard shown else { return false }
        showing = true
        Task {
            try? await Task.sleep(for: .seconds(time.total + 0.3))
            showing = false
            showNext()
        }
        return true
    }

    private func showNext() {
        guard !muted, !screensAsleep, !Self.screenLocked() else { return queue.removeAll() }
        while let next = queue.next() {
            if present(next.effect, from: next.sender, message: next.message) { return }
        }
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

    private func receive(from sender: String, _ check: RequestCheck) -> AckStatus? {
        switch check {
        case .unreadable:
            return nil
        case .invalid:
            return .invalid
        case .valid(let id, let effect, let message, let acceptsQueued):
            // ponytail: the name comes from the sender's own Bonjour record, so it can be spoofed;
            // accepted with the no-pairing decision.
            let name = peers.first { sender.hasPrefix($0.hint) }.map(label) ?? "未知裝置（\(sender.prefix(4))）"
            let text = showMessages ? message : nil
            return gate.decide(sender: sender, id: id, now: .now, muted: muted, busy: showing,
                               acceptsQueued: acceptsQueued,
                               enqueue: { queue.add(Pending(effect: effect, sender: name, message: text), from: sender) }) {
                !screensAsleep && !Self.screenLocked() && present(effect, from: name, message: text)
            }
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
        network.onRequest = { [weak self] in self?.receive(from: $0, $1) }
        network.onPeersChanged = { [weak self] in self?.peers = $0.sorted { $0.name < $1.name } }
        network.onProblem = { [weak self] in self?.networkProblem = $0 }
        network.start()
        self.network = network
    }
}
