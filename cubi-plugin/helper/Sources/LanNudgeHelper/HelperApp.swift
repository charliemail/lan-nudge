import Foundation

/// Where the user's display name lives: set from the plugin's panel through Cubi (`call setName`),
/// never taken from the Mac (its name often is the owner's real name).
protocol NameStore: AnyObject {
    var name: String? { get set }
}

/// What DefaultsNameStore needs of UserDefaults.
protocol StringDefaults: AnyObject {
    func string(forKey: String) -> String?
    func set(_ value: Any?, forKey: String)
}

extension UserDefaults: StringDefaults {}

/// In defaults, as the app keeps its name in its own. `.standard` is the helper's own domain: its
/// embedded Info.plist names it (dev.lannudge.cubi-helper). Opening that as a suite does not work:
/// Foundation refuses a suite named after the process's own bundle identifier.
final class DefaultsNameStore: NameStore {
    static let key = "displayName"
    let defaults: StringDefaults
    init(_ defaults: StringDefaults = UserDefaults.standard) { self.defaults = defaults }
    var name: String? {
        get { defaults.string(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// The helper once Cubi said hello. Until the user has set a name nothing touches the network or
/// the keychain, as the app waits for its first-run setup; `state` says `needsName` meanwhile.
@MainActor
final class HelperApp {
    /// `state` at most this often; the last change always goes out.
    static let stateInterval: Duration = .seconds(1)

    private let channel: CubiChannel
    private let store: NameStore
    private let makeNetwork: (String) throws -> PeerNetwork
    private(set) var service: NudgeService?
    /// What stops it from working, for the panel to show (the keychain, local network access).
    private(set) var problem: String?
    private var stateDue = false
    private var stateScheduled = false

    /// `makeNetwork`: the identity and PeerNetwork for a name; started only once a name is set.
    init(channel: CubiChannel, store: NameStore, makeNetwork: @escaping (String) throws -> PeerNetwork) {
        self.channel = channel
        self.store = store
        self.makeNetwork = makeNetwork
    }

    func start() {
        if let name = store.name { startNetwork(name) }
        stateChanged()
    }

    private func startNetwork(_ name: String) {
        if let service {
            service.setDisplayName(name)
            return
        }
        do {
            let network = try makeNetwork(name)
            service = NudgeService(network: network,
                                   present: { [channel] in channel.present(effect: $0, from: $1, windowShaken: false) },
                                   peersChanged: { [weak self] in self?.stateChanged() })
            network.onProblem = { [weak self, channel] problem in
                if let problem { channel.log(problem) }
                self?.setProblem(problem)
            }
            network.start()
            channel.log("lan-nudge helper ready")
        } catch {
            channel.log("鑰匙圈：\(error.localizedDescription)")
            setProblem("鑰匙圈：\(error.localizedDescription)")
        }
    }

    private func setProblem(_ text: String?) {
        problem = text.map { CubiChannel.plain($0, limit: CubiChannel.logLimit, fallback: "-") }
        stateChanged()
    }

    // MARK: - State

    /// What Cubi keeps for the panel: whether a name is needed, the name, what is wrong if anything,
    /// and the peers, kept under Cubi's line limit by leaving peers off the end.
    static func stateData(name: String?, peers: [Peer], problem: String? = nil) -> [String: Any] {
        var list = NudgeService.list(peers)
        var data: [String: Any] = ["needsName": name == nil, "peers": list]
        if let name { data["name"] = name }
        if let problem { data["problem"] = problem }
        while CubiChannel.stateSize(data) > CubiChannel.lineLimit, !list.isEmpty {
            list.removeLast()
            data["peers"] = list
        }
        return data
    }

    func stateChanged() {
        stateDue = true
        guard !stateScheduled else { return }
        stateScheduled = true
        sendState()
    }

    private func sendState() {
        guard stateDue else { stateScheduled = false; return }
        stateDue = false
        channel.state(Self.stateData(name: store.name, peers: service?.peers ?? [], problem: problem))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.stateInterval)
            self?.sendState()
        }
    }

    // MARK: - Calls from the panel

    func handle(_ call: CubiChannel.Call) async -> (ok: Bool, out: [String: Any]) {
        switch call.action {
        case "setName":
            let name = CubiChannel.plain(call.args["name"] ?? "", limit: CubiChannel.nameLimit, fallback: "")
            guard !name.isEmpty else { return (false, ["error": "名稱要有字，最多 \(CubiChannel.nameLimit) 字"]) }
            store.name = name
            startNetwork(name)
            stateChanged()
            return (true, ["name": name])
        case "send":
            guard let service else { return (false, ["error": "請先設定名稱"]) }
            return await service.send(peerID: call.args["peer"] ?? "", effect: call.args["effect"] ?? "")
        default:
            return (false, ["error": "不認得的動作 \(CubiChannel.plain(call.action, limit: CubiChannel.nameLimit, fallback: "?"))"])
        }
    }
}
