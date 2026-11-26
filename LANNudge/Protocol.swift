import Foundation

enum Effect: String, Codable, CaseIterable, Sendable {
    case cartoonShock
    case shake
    case knock
    case funnyFace

    var title: String {
        switch self {
        case .cartoonShock: "小人觸電"
        case .shake: "視窗震動"
        case .knock: "敲門"
        case .funnyFace: "做鬼臉"
        }
    }

    /// SF Symbol for menus, the control panel and the nudge card. 做鬼臉 shows the character itself
    /// (`EffectIcon`); its symbol is the fallback.
    var symbol: String {
        switch self {
        case .cartoonShock: "bolt.fill"
        case .shake: "iphone.radiowaves.left.and.right"
        case .knock: "door.left.hand.closed"
        case .funnyFace: "theatermasks.fill"
        }
    }
}

enum Wire {
    static let version = 1
    static let bonjourType = "_lannudge._tcp"
    static let maxPayloadBytes = 4096
    static let deadline: Duration = .seconds(5)
}

/// `message` and `acceptsQueued` are optional additions to version 1: receivers before 0.4.0 ignore
/// unknown keys, so the version stays 1 and old and new copies interoperate.
struct NudgeRequest: Codable, Equatable {
    var version = Wire.version
    var type = "nudge"
    let id: UUID
    let effect: Effect
    var message: String?
    /// Senders before 0.4.0 can't decode a `queued` ack (they'd report "no ack"), so the receiver
    /// only queues requests that set this.
    var acceptsQueued = true
}

enum AckStatus: String, Codable, Sendable {
    case displayed, queued, muted, rateLimited, unavailable, invalid
}

enum NudgeMessage {
    static let maxLength = 60

    /// Applied on both ends; the receiver never trusts the sender's copy. Control characters
    /// (newlines included) and bidi overrides become spaces so a message can't break the layout
    /// or display reversed text; length counts user-perceived characters.
    static func sanitize(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.map {
            // Not CharacterSet.controlCharacters: it also holds format characters such as the ZWJ
            // that joins emoji sequences.
            $0.properties.generalCategory == .control || (0x202A...0x202E).contains($0.value)
                || (0x2066...0x2069).contains($0.value) ? " " : $0
        }))
        let collapsed = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : String(collapsed.prefix(maxLength))
    }
}

/// Sent back to a nudge's sender when the receiver clicks 確認 on it (sticky mode). Copies before
/// 0.5.0 answer it `invalid` and show nothing, so it needs no version change either.
struct ReadReceipt: Codable, Equatable {
    var version = Wire.version
    var type = "read"
    let id: UUID
}

struct Ack: Codable, Equatable {
    var version = Wire.version
    var type = "ack"
    let id: UUID
    let status: AckStatus
}

/// Outcome of parsing an incoming payload. Unknown versions/effects still yield the id when it is
/// readable, so the sender gets an `invalid` ack instead of a silent drop.
enum RequestCheck: Equatable {
    case valid(id: UUID, effect: Effect, message: String?, acceptsQueued: Bool)
    /// A `ReadReceipt` for a nudge this copy sent.
    case read(id: UUID)
    case invalid(id: UUID)
    case unreadable

    var id: UUID? {
        switch self {
        case .valid(let id, _, _, _), .read(let id), .invalid(let id): id
        case .unreadable: nil
        }
    }

    init(_ payload: Data) {
        struct Loose: Decodable {
            let version: Int?
            let type: String?
            let id: UUID?
            let effect: String?
            let message: String?
            let acceptsQueued: Bool?
        }
        guard let loose = try? JSONDecoder().decode(Loose.self, from: payload), let id = loose.id else {
            self = .unreadable
            return
        }
        if loose.version == Wire.version, loose.type == "read" {
            self = .read(id: id)
            return
        }
        guard loose.version == Wire.version, loose.type == "nudge",
              let effect = loose.effect.flatMap(Effect.init(rawValue:)) else {
            self = .invalid(id: id)
            return
        }
        self = .valid(id: id, effect: effect, message: NudgeMessage.sanitize(loose.message),
                      acceptsQueued: loose.acceptsQueued ?? false)
    }
}

/// 4-byte big-endian length prefix + UTF-8 JSON. TCP has no message boundaries, so the decoder
/// buffers partial reads and checks the length before waiting for the payload.
enum FrameCodec {
    enum Failure: Error, Equatable {
        case emptyFrame
        case frameTooLarge(Int)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= Wire.maxPayloadBytes else { throw Failure.frameTooLarge(payload.count) }
        var frame = withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) }
        frame.append(payload)
        return frame
    }

    struct Decoder {
        private var buffer = Data()

        /// Returns every complete payload. Throws on a length the peer must not send; the caller
        /// drops the connection rather than trying to resync.
        mutating func push(_ bytes: Data) throws -> [Data] {
            buffer.append(bytes)
            var frames: [Data] = []
            while buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
                guard length > 0 else { throw Failure.emptyFrame }
                guard length <= Wire.maxPayloadBytes else { throw Failure.frameTooLarge(length) }
                guard buffer.count >= 4 + length else { break }
                frames.append(Data(buffer.dropFirst(4).prefix(length)))
                buffer = Data(buffer.dropFirst(4 + length))
            }
            return frames
        }
    }
}
