import Foundation

/// The helper's side of Cubi's service protocol after `hello`: one JSON object per line. Events go
/// out on stdout; `presented` answers and `call`s come in on stdin. Cubi checks every event, and
/// refuses text with control, line-separator or direction characters, so names that came over the
/// network are cleaned here first (`plain`).
final class CubiChannel: @unchecked Sendable {
    /// What Cubi accepts for `title`/`from` (ServiceProtocol.titleLimit) and for `log` text.
    static let nameLimit = 40
    static let logLimit = 200
    /// How long a nudge waits for Cubi to say whether it drew the overlay.
    static let presentWait: TimeInterval = 1.5
    /// Cubi drops a longer line whole (ServiceProtocol.lineLimit), newline not counted.
    static let lineLimit = 16_384

    struct Call: Equatable {
        let id: Int
        let action: String
        let args: [String: String]
    }

    private let lock = NSLock()
    private let output: (Data) -> Void
    private var nextPresent = 0
    private var waiting: [Int: (DispatchSemaphore, Box)] = [:]

    private final class Box: @unchecked Sendable { var shown: Bool? }

    init(output: @escaping (Data) -> Void = { FileHandle.standardOutput.write($0) }) {
        self.output = output
    }

    // MARK: - Out

    func log(_ text: String) {
        emit(["type": "log", "text": Self.plain(text, limit: Self.logLimit, fallback: "-")])
    }

    func state(_ data: [String: Any]) {
        emit(["type": "state", "data": data])
    }

    /// Bytes of the `state` line `data` makes, newline not counted.
    static func stateSize(_ data: [String: Any]) -> Int {
        (try? JSONSerialization.data(withJSONObject: ["type": "state", "data": data], options: [.sortedKeys]))?.count ?? Int.max
    }

    func reply(id: Int, ok: Bool, out: [String: Any]) {
        emit(["type": "reply", "id": id, "ok": ok, "out": out])
    }

    /// Asks Cubi to draw the overlay and waits up to `presentWait` for its answer. Blocks the
    /// caller: LAN Nudge's PeerNetwork answers a request synchronously, so the answer must be known
    /// before returning. Nothing else of the helper's runs meanwhile but the stdin reader.
    func present(effect: String, from: String, windowShaken: Bool) -> Bool {
        let semaphore = DispatchSemaphore(value: 0), box = Box()
        lock.lock()
        nextPresent += 1
        let id = nextPresent
        waiting[id] = (semaphore, box)
        lock.unlock()
        emit(["type": "present", "id": id, "effect": effect,
              "from": Self.plain(from, limit: Self.nameLimit, fallback: "未知裝置"), "windowShaken": windowShaken])
        _ = semaphore.wait(timeout: .now() + Self.presentWait)
        lock.lock(); defer { lock.unlock() }
        waiting[id] = nil
        return box.shown ?? false
    }

    private func emit(_ object: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        line.append(0x0a)
        lock.lock(); defer { lock.unlock() }
        output(line)
    }

    // MARK: - In

    /// One stdin line: a `presented` wakes its waiter; a `call` is returned for the caller to run.
    func take(_ line: Data) -> Call? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String, let id = Self.int(object["id"]) else { return nil }
        switch type {
        case "presented":
            lock.lock(); defer { lock.unlock() }
            guard let (semaphore, box) = waiting[id] else { return nil }
            box.shown = object["ok"] as? Bool == true
            semaphore.signal()
            return nil
        case "call":
            guard let action = object["action"] as? String else { return nil }
            let args = (object["args"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            return Call(id: id, action: action, args: args)
        default:
            return nil
        }
    }

    /// A whole number, not a Bool that JSONSerialization also hands back as NSNumber.
    private static func int(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: n.doubleValue)
    }

    // MARK: - Text from the network

    /// Text Cubi will take: control, line-separator and direction characters removed, whitespace
    /// runs made one space, at most `limit` characters and 4 × `limit` scalars; `fallback` when
    /// nothing visible is left.
    static func plain(_ text: String, limit: Int, fallback: String) -> String {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = false
        for u in text.unicodeScalars {
            let v = u.value
            if v < 0x20 || v == 0x7f || (0x80...0x9f).contains(v) || v == 0x2028 || v == 0x2029 || u.properties.isBidiControl { continue }
            let space = u.properties.isWhitespace
            if space && lastWasSpace { continue }
            scalars.append(space ? " " : u)
            lastWasSpace = space
        }
        var s = String(scalars).trimmingCharacters(in: .whitespaces)
        if s.count > limit { s = String(s.prefix(limit)) }
        while s.unicodeScalars.count > limit * 4 { s = String(s.dropLast()) }
        let visible = s.unicodeScalars.contains { !$0.properties.isWhitespace && !$0.properties.isDefaultIgnorableCodePoint }
        return visible ? s : fallback
    }
}
