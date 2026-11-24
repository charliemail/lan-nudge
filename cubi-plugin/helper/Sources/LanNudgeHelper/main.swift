import Foundation

// LAN Nudge as a Cubi plugin service. Cubi starts it, writes `hello` on stdin, and reads one JSON
// event per line on stdout. Without Cubi's hello it exits before touching anything; without a
// display name set from the panel it waits, off the network and out of the keychain.

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("lan-nudge helper: \(message)\n".utf8))
    exit(code)
}

switch CubiHello.readFirstLine().map(CubiHello.greeting) ?? .notHello {
case .accepted:
    break
case .otherProtocol(let n):
    fail("Cubi 說的是 protocol \(n)，這個輔助程式只會 \(CubiHello.protocolVersion)；請更新套件或 Cubi", code: 0)
case .notHello:
    fail("沒有收到 Cubi 的 hello（protocol \(CubiHello.protocolVersion)），結束", code: 64)
}

/// Its own identity in the login keychain, apart from the app's ("LAN Nudge Identity"): the
/// plugin and the app are two devices to their peers.
let identityLabel = "Cubi LAN Nudge Identity"

// Cubi's offline panel picture: the name as stored, nothing written, off the network and keychain.
let dryRun = ProcessInfo.processInfo.environment["CUBI_RENDER"] == "1"
let channel = CubiChannel()
let app = HelperApp(channel: channel, store: dryRun ? MemoryNameStore(copying: DefaultsNameStore()) : DefaultsNameStore(),
                    dryRun: dryRun) { name in
    PeerNetwork(identity: try LocalIdentity.loadOrCreate(label: identityLabel), displayName: name)
}
app.start()

// stdin after hello: `presented` answers wake the waiting request; `call`s run on the main actor.
// Its end (Cubi quit, the plugin turned off) ends the helper.
Thread.detachNewThread {
    var buffer = Data()
    while true {
        let chunk = FileHandle.standardInput.availableData
        if chunk.isEmpty { exit(0) }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[buffer.startIndex..<nl])
            buffer = Data(buffer[buffer.index(after: nl)...])
            guard let call = channel.take(line) else { continue }
            Task { @MainActor in
                let result = await app.handle(call)
                channel.reply(id: call.id, ok: result.ok, out: result.out)
            }
        }
        // A line past Cubi's own limit is not one of Cubi's.
        if buffer.count > CubiChannel.lineLimit { buffer.removeAll() }
    }
}

RunLoop.main.run()
