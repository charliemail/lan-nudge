import Foundation
import Testing
@testable import LanNudgeHelper

// The helper before and after the user sets a name. `makeNetwork` only records the name it was
// asked for and throws: nothing here touches the keychain or the network. Lines are what the
// channel writes; `setName`, `send` and their args are the calls the plugin's panel will make.

private final class MemoryNames: NameStore {
    var name: String?
}

private struct NoNetwork: Error {}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func write(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var objects: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return data.split(separator: 0x0a).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }
    var states: [[String: Any]] { objects.filter { $0["type"] as? String == "state" }.compactMap { $0["data"] as? [String: Any] } }
}

@MainActor
@Test func withoutANameNothingStartsAndTheStateSaysSo() async throws {
    let lines = Lines(), names = MemoryNames()
    var asked: [String] = []
    let app = HelperApp(channel: CubiChannel(output: lines.write), store: names) { name in
        asked.append(name); throw NoNetwork()
    }
    app.start()
    #expect(asked.isEmpty)
    #expect(app.service == nil)
    #expect(lines.states.last?["needsName"] as? Bool == true)
    #expect(lines.states.last?["name"] == nil)

    // Sending before a name: refused, still nothing started.
    let send = await app.handle(CubiChannel.Call(id: 1, action: "send", args: ["peer": "LANNudge-0", "effect": "zap"]))
    #expect(!send.ok && asked.isEmpty)

    // A name with nothing visible in it is no name.
    let blank = await app.handle(CubiChannel.Call(id: 2, action: "setName", args: ["name": "\n\u{202E} "]))
    #expect(!blank.ok && names.name == nil && asked.isEmpty)

    // A name: kept (made plain), and only now is the network asked for, with it.
    let set = await app.handle(CubiChannel.Call(id: 3, action: "setName", args: ["name": " alpha\u{2028} "]))
    #expect(set.ok && set.out["name"] as? String == "alpha")
    #expect(names.name == "alpha")
    #expect(asked == ["alpha"])
    // The network could not be made (here it always throws, as a refused keychain would): the
    // state says why, for the panel, instead of an empty neighbourhood (F-P2-6).
    #expect((app.problem ?? "").hasPrefix("鑰匙圈："))

    // The state follows, at most once per interval, the last change included.
    try await Task.sleep(for: HelperApp.stateInterval + .milliseconds(300))
    #expect(lines.states.last?["needsName"] as? Bool == false)
    #expect(lines.states.last?["name"] as? String == "alpha")
    #expect((lines.states.last?["problem"] as? String ?? "").hasPrefix("鑰匙圈："))
    #expect(lines.states.count <= 2)

    // Unknown actions are refused, their name made plain for the answer.
    let other = await app.handle(CubiChannel.Call(id: 4, action: "rm\n-rf", args: [:]))
    #expect(!other.ok && (other.out["error"] as? String)?.contains("\n") == false)
}

@MainActor
@Test func aNameAlreadySetStartsTheNetworkRightAway() {
    let names = MemoryNames()
    names.name = "alpha"
    var asked: [String] = []
    let app = HelperApp(channel: CubiChannel(output: { _ in }), store: names) { name in
        asked.append(name); throw NoNetwork()
    }
    app.start()
    #expect(asked == ["alpha"])
}

@MainActor
@Test func manyChangesMakeFewStatesAndTheLastOneGoesOut() async throws {
    let lines = Lines(), names = MemoryNames()
    let app = HelperApp(channel: CubiChannel(output: lines.write), store: names) { _ in throw NoNetwork() }
    for _ in 0..<20 { app.stateChanged() }
    #expect(lines.states.count == 1)
    names.name = "alpha"
    app.stateChanged()
    try await Task.sleep(for: HelperApp.stateInterval + .milliseconds(300))
    #expect(lines.states.count == 2)
    #expect(lines.states.last?["name"] as? String == "alpha")
}

// F-P2-5 (review of P2 v2): a suite named after the helper's own bundle identifier is nil, so the
// name was never kept. The store now uses the standard defaults, the helper's own domain; that
// standard defaults keep a value across runs is Foundation's (the reviewer's probe: set, read back
// in the next run, seen by `defaults read`). Here: the default is .standard, and the store reads
// back what it wrote, through an in-memory stand-in so the test writes nothing to disk.
private final class MemoryDefaults: StringDefaults {
    var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@Test func theNameIsKeptInTheHelpersOwnDefaults() {
    #expect(DefaultsNameStore().defaults === UserDefaults.standard)
    let memory = MemoryDefaults()
    let store = DefaultsNameStore(memory)
    #expect(store.name == nil)
    store.name = "alpha"
    #expect(memory.values[DefaultsNameStore.key] as? String == "alpha")
    #expect(DefaultsNameStore(memory).name == "alpha")
}

@MainActor
@Test func theStateCarriesAProblemOnlyWhenThereIsOne() {
    #expect(HelperApp.stateData(name: "alpha", peers: [])["problem"] == nil)
    #expect(HelperApp.stateData(name: "alpha", peers: [], problem: "x")["problem"] as? String == "x")
}
