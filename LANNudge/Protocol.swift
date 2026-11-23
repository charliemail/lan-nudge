import Foundation

enum Effect: String, Codable, CaseIterable, Sendable {
    case cartoonShock
    case shake
    case knock

    var title: String {
        switch self {
        case .cartoonShock: "小人觸電"
        case .shake: "視窗震動"
        case .knock: "敲門"
        }
    }
}

enum Wire {
    static let version = 1
    static let bonjourType = "_lannudge._tcp"
    static let maxPayloadBytes = 4096
    static let deadline: Duration = .seconds(5)
}

struct NudgeRequest: Codable, Equatable {
    var version = Wire.version
    var type = "nudge"
    let id: UUID
    let effect: Effect
}

enum AckStatus: String, Codable, Sendable {
    case displayed, muted, rateLimited, unavailable, invalid
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
    case valid(id: UUID, effect: Effect)
    case invalid(id: UUID)
    case unreadable

    var id: UUID? {
        switch self {
        case .valid(let id, _), .invalid(let id): id
        case .unreadable: nil
        }
    }

    init(_ payload: Data) {
        struct Loose: Decodable {
            let version: Int?
            let type: String?
            let id: UUID?
            let effect: String?
        }
        guard let loose = try? JSONDecoder().decode(Loose.self, from: payload), let id = loose.id else {
            self = .unreadable
            return
        }
        guard loose.version == Wire.version, loose.type == "nudge",
              let effect = loose.effect.flatMap(Effect.init(rawValue:)) else {
            self = .invalid(id: id)
            return
        }
        self = .valid(id: id, effect: effect)
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
