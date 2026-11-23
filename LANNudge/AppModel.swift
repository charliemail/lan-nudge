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
    var muted: Bool { didSet { defaults.set(muted, forKey: "muted") } }
    private(set) var peers: [Peer] = []
    private(set) var networkProblem: String?
    private(set) var identityError: String?
    private(set) var lastResult: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var identity: LocalIdentity?
    @ObservationIgnored private var network: PeerNetwork?
    @ObservationIgnored private var gate = ReceiveGate()
    @ObservationIgnored private var screensAsleep = false

    init() {
        defaults = instance.flatMap { UserDefaults(suiteName: "dev.lannudge.instance.\($0)") } ?? .standard
        displayName = defaults.string(forKey: "displayName") ?? ""
        muted = defaults.bool(forKey: "muted")

        do {
            identity = try LocalIdentity.loadOrCreate(label: "LAN Nudge Identity" + (instance.map { " \($0)" } ?? ""))
        } catch {
            identityError = error.localizedDescription
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = true }
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

    func nudge(_ peer: Peer, with effect: Effect) {
        guard let network else { return }
        let name = label(for: peer)
        lastResult = "\(name)：傳送中…"
        Task {
            let outcome = await network.send(effect, to: peer)
            lastResult = "\(name)：\(outcome.message)"
        }
    }

    private func receive(from sender: String, _ check: RequestCheck) -> AckStatus? {
        switch check {
        case .unreadable:
            return nil
        case .invalid:
            return .invalid
        case .valid(let id, let effect):
            // ponytail: the name comes from the sender's own Bonjour record, so it can be spoofed;
            // accepted with the no-pairing decision.
            let name = peers.first { sender.hasPrefix($0.hint) }.map(label) ?? "未知裝置（\(sender.prefix(4))）"
            let overlay = OverlayController.shared
            return gate.decide(sender: sender, id: id, now: .now, muted: muted, busy: overlay.isShowing) {
                !screensAsleep && !Self.screenLocked() && overlay.show(effect, from: name)
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
