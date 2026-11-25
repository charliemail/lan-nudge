import Foundation

/// Where the user's display name lives: set from the plugin's panel through Cubi (`call set-name`),
/// never taken from the Mac (its name often is the owner's real name).
protocol NameStore: AnyObject {
    var name: String? { get set }
    /// 暫停接收, kept as the app keeps it.
    var muted: Bool { get set }
}

/// What DefaultsNameStore needs of UserDefaults.
protocol StringDefaults: AnyObject {
    func string(forKey: String) -> String?
    func bool(forKey: String) -> Bool
    func set(_ value: Any?, forKey: String)
}

extension UserDefaults: StringDefaults {}

/// In defaults, as the app keeps its name in its own. `.standard` is the helper's own domain: its
/// embedded Info.plist names it (dev.lannudge.cubi-helper). Opening that as a suite does not work:
/// Foundation refuses a suite named after the process's own bundle identifier.
final class DefaultsNameStore: NameStore {
    static let key = "displayName"
    static let mutedKey = "muted"
    let defaults: StringDefaults
    init(_ defaults: StringDefaults = UserDefaults.standard) { self.defaults = defaults }
    var name: String? {
        get { defaults.string(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
    var muted: Bool {
        get { defaults.bool(forKey: Self.mutedKey) }
        set { defaults.set(newValue, forKey: Self.mutedKey) }
    }
}

/// For a dry run: what the user's store held, read once, then kept in memory only.
final class MemoryNameStore: NameStore {
    var name: String?
    var muted: Bool
    init(copying store: NameStore) {
        name = store.name
        muted = store.muted
    }
}

/// The helper once Cubi said hello. Until the user has set a name nothing touches the network or
/// the keychain, as the app waits for its first-run setup; `state` says `needsName` meanwhile.
/// In a dry run (Cubi's offline panel picture, `CUBI_RENDER=1`) it never does.
@MainActor
final class HelperApp {
    /// `state` at most this often; the last change always goes out.
    static let stateInterval: Duration = .seconds(1)

    private let channel: CubiChannel
    private let store: NameStore
    private let makeNetwork: (String) throws -> PeerNetwork
    private let dryRun: Bool
    private(set) var service: NudgeService?
    /// What stops it from working, for the panel to show (the keychain, local network access).
    private(set) var problem: String?
    private var stateDue = false
    private var stateScheduled = false

    /// `makeNetwork`: the identity and PeerNetwork for a name; started only once a name is set.
    init(channel: CubiChannel, store: NameStore, dryRun: Bool = false, makeNetwork: @escaping (String) throws -> PeerNetwork) {
        self.channel = channel
        self.store = store
        self.dryRun = dryRun
        self.makeNetwork = makeNetwork
    }

    func start() {
        if let name = store.name { startNetwork(name) }
        stateChanged()
        watchAccessibility()
    }

    /// The Accessibility permission is granted in System Settings, outside the helper: looked at
    /// every few seconds, and a change goes out in the state (the panel's hint).
    static let accessibilityCheck: Duration = .seconds(5)
    private var accessibility = WindowShaker.isTrusted

    private func watchAccessibility() {
        Task { @MainActor [weak self] in
            while let self {
                try? await Task.sleep(for: Self.accessibilityCheck)
                let now = WindowShaker.isTrusted
                if now != self.accessibility {
                    self.accessibility = now
                    self.stateChanged()
                }
            }
        }
    }

    private func startNetwork(_ name: String) {
        guard !dryRun else { return setProblem("預覽：不上網路、不碰鑰匙圈") }
        if let service {
            service.setDisplayName(name)
            return
        }
        do {
            let network = try makeNetwork(name)
            let service = NudgeService(network: network,
                                       present: { [channel] in channel.present(effect: $0, from: $1, message: $2, seconds: $3, windowShaken: $4) },
                                       peersChanged: { [weak self] in self?.stateChanged() })
            service.setMuted(store.muted)
            self.service = service
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
    static func stateData(name: String?, peers: [Peer], problem: String? = nil, muted: Bool = false, accessibility: Bool = true) -> [String: Any] {
        var list = NudgeService.list(peers)
        var data: [String: Any] = ["needsName": name == nil, "muted": muted, "accessibility": accessibility, "peers": list]
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
        channel.state(Self.stateData(name: store.name, peers: service?.peers ?? [], problem: problem, muted: store.muted, accessibility: accessibility))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.stateInterval)
            self?.sendState()
        }
    }

    // MARK: - Calls from the panel

    func handle(_ call: CubiChannel.Call) async -> (ok: Bool, out: [String: Any]) {
        switch call.action {
        case "set-name":
            let name = CubiChannel.plain(call.args["name"] ?? "", limit: CubiChannel.nameLimit, fallback: "")
            guard !name.isEmpty else { return (false, ["error": "名稱要有字，最多 \(CubiChannel.nameLimit) 字"]) }
            store.name = name
            startNetwork(name)
            stateChanged()
            return (true, ["name": name])
        case "set-muted":
            // "true" or "false": a call's args are strings.
            guard let raw = call.args["muted"], ["true", "false"].contains(raw) else { return (false, ["error": "muted 要是 true 或 false"]) }
            store.muted = raw == "true"
            service?.setMuted(store.muted)
            stateChanged()
            return (true, ["muted": store.muted])
        case "status":
            // What the last `state` said, asked for: Cubi has none until the first is sent.
            return (true, Self.stateData(name: store.name, peers: service?.peers ?? [], problem: problem, muted: store.muted, accessibility: accessibility))
        case "preview":
            // The app's 預覽動畫: on this Mac only, nothing over the network.
            guard let name = call.args["effect"], let effect = NudgeService.effect(cubi: name) else {
                return (false, ["error": "effect 只能是 knock、zap、shake"])
            }
            // With the network up, through the service: nudges arriving meanwhile queue behind it.
            let answer = service?.preview(effect, from: store.name ?? "預覽")
                ?? channel.present(effect: name, from: store.name ?? "預覽", seconds: NudgeService.overlaySeconds, windowShaken: false)
            switch answer {
            case .shown: return (true, ["result": "預覽中"])
            case .busy: return (false, ["error": "上一則還在畫面上"])
            case .unavailable: return (false, ["error": "現在無法顯示"])
            }
        case "request-accessibility":
            // The app's 開啟輔助使用權限…: the system's own prompt, for the helper (its responsible process).
            guard !dryRun else { return (false, ["error": "預覽：不要求權限"]) }
            WindowShaker.requestPermission()
            return (true, ["accessibility": WindowShaker.isTrusted])
        case "send":
            guard !dryRun else { return (false, ["error": "預覽：不送出"]) }
            guard let service else { return (false, ["error": "請先設定名稱"]) }
            return await service.send(peerID: call.args["peer"] ?? "", effect: call.args["effect"] ?? "", message: call.args["message"])
        default:
            return (false, ["error": "不認得的動作 \(CubiChannel.plain(call.action, limit: CubiChannel.nameLimit, fallback: "?"))"])
        }
    }
}
