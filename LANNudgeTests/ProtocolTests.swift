import Foundation
import Testing
@testable import LANNudge

struct FrameCodecTests {
    @Test func reassemblesFrameSplitAcrossReads() throws {
        let frame = try FrameCodec.encode(NudgeRequest(id: UUID(), effect: .shake))
        var decoder = FrameCodec.Decoder()
        // Split inside the length prefix and inside the payload.
        #expect(try decoder.push(frame.prefix(2)).isEmpty)
        #expect(try decoder.push(frame.dropFirst(2).prefix(10)).isEmpty)
        let frames = try decoder.push(frame.dropFirst(12))
        #expect(frames == [frame.dropFirst(4)].map { Data($0) })
    }

    @Test func yieldsSeveralFramesFromOneRead() throws {
        let a = try FrameCodec.encode(Ack(id: UUID(), status: .displayed))
        let b = try FrameCodec.encode(Ack(id: UUID(), status: .muted))
        var decoder = FrameCodec.Decoder()
        #expect(try decoder.push(a + b).count == 2)
    }

    @Test func rejectsOversizedLengthBeforePayloadArrives() {
        var decoder = FrameCodec.Decoder()
        let header = withUnsafeBytes(of: UInt32(Wire.maxPayloadBytes + 1).bigEndian) { Data($0) }
        #expect(throws: FrameCodec.Failure.frameTooLarge(Wire.maxPayloadBytes + 1)) { try decoder.push(header) }
    }

    @Test func acceptsExactlyMaxPayload() throws {
        var decoder = FrameCodec.Decoder()
        let header = withUnsafeBytes(of: UInt32(Wire.maxPayloadBytes).bigEndian) { Data($0) }
        #expect(try decoder.push(header + Data(count: Wire.maxPayloadBytes)).count == 1)
    }

    @Test func rejectsEmptyFrame() {
        var decoder = FrameCodec.Decoder()
        #expect(throws: FrameCodec.Failure.emptyFrame) { try decoder.push(Data(count: 4)) }
    }

    @Test func encodeRefusesOversizedMessage() {
        struct Big: Encodable { let s = String(repeating: "x", count: Wire.maxPayloadBytes) }
        #expect(throws: FrameCodec.Failure.self) { try FrameCodec.encode(Big()) }
    }
}

struct RequestCheckTests {
    let id = UUID()

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func validRequest() throws {
        let payload = try JSONEncoder().encode(NudgeRequest(id: id, effect: .cartoonShock))
        #expect(RequestCheck(payload) == .valid(id: id, effect: .cartoonShock, message: nil, acceptsQueued: true))
        #expect(!String(decoding: payload, as: UTF8.self).contains("message"))
    }

    @Test func requestWithMessage() throws {
        let payload = try JSONEncoder().encode(NudgeRequest(id: id, effect: .knock, message: "來開會了"))
        #expect(RequestCheck(payload) == .valid(id: id, effect: .knock, message: "來開會了", acceptsQueued: true))
    }

    @Test func readReceipt() throws {
        #expect(RequestCheck(try JSONEncoder().encode(ReadReceipt(id: id))) == .read(id: id))
        #expect(RequestCheck(json(["version": 2, "type": "read", "id": id.uuidString])) == .invalid(id: id))
    }

    /// Pre-0.4.0 senders send neither key: no message, and they can't read a `queued` ack.
    @Test func oldSenderFormat() {
        #expect(RequestCheck(json(["version": 1, "type": "nudge", "id": id.uuidString, "effect": "shake"]))
                == .valid(id: id, effect: .shake, message: nil, acceptsQueued: false))
    }

    /// The receiver cleans the text itself instead of trusting the sender.
    @Test func receivedMessageIsSanitized() {
        let raw = "第一行\n第二行\u{202E}反轉\t" + String(repeating: "字", count: 80)
        guard case .valid(_, _, let message?, _) = RequestCheck(json(["version": 1, "type": "nudge", "id": id.uuidString,
                                                                     "effect": "shake", "message": raw])) else {
            Issue.record("expected a message"); return
        }
        #expect(!message.contains("\n") && !message.contains("\u{202E}") && !message.contains("\t"))
        #expect(message.hasPrefix("第一行 第二行 反轉 字"))
        #expect(message.count == NudgeMessage.maxLength)
    }

    @Test func sanitizeEdgeCases() {
        #expect(NudgeMessage.sanitize(nil) == nil)
        #expect(NudgeMessage.sanitize(" \n\t ") == nil)
        #expect(NudgeMessage.sanitize("  hi   there ") == "hi there")
        // A family emoji is one character (joined with ZWJ, which is kept).
        let family = "👨‍👩‍👧"
        #expect(NudgeMessage.sanitize(String(repeating: family, count: 70))?.count == 60)
        #expect(NudgeMessage.sanitize(family) == family)
    }

    @Test func unknownVersionIsInvalidWithID() {
        #expect(RequestCheck(json(["version": 2, "type": "nudge", "id": id.uuidString, "effect": "shake"])) == .invalid(id: id))
    }

    @Test func unknownEffectIsInvalidWithID() {
        #expect(RequestCheck(json(["version": 1, "type": "nudge", "id": id.uuidString, "effect": "explode"])) == .invalid(id: id))
    }

    @Test func wrongTypeIsInvalid() {
        #expect(RequestCheck(json(["version": 1, "type": "ack", "id": id.uuidString, "effect": "shake"])) == .invalid(id: id))
    }

    @Test func unreadableIDGetsNoReply() {
        #expect(RequestCheck(json(["version": 1, "type": "nudge", "id": "nope", "effect": "shake"])) == .unreadable)
        #expect(RequestCheck(Data("not json".utf8)) == .unreadable)
    }
}
