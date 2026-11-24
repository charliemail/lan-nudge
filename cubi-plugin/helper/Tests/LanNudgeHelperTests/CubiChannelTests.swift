import Foundation
import Testing
@testable import LanNudgeHelper

// Inputs: the characters Cubi's ServiceProtocol refuses in text (Cubi commit 6cd6767:
// isForbidden — C0, DEL, C1, U+2028/2029, Bidi_Control such as U+202E; isBlank), the limits it
// sets (titleLimit 40, logLimit 200, the ×4 scalar cap), and Cubi's own lines (`presented`, `call`)
// as its ServiceProtocol writes them.

/// Collects what the channel writes.
private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func write(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var lines: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return data.split(separator: 0x0a).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }
}

@Test func networkTextIsMadeWhatCubiTakes() {
    let limit = CubiChannel.nameLimit
    #expect(CubiChannel.plain("a\nb\u{1B}c", limit: limit, fallback: "x") == "abc")
    #expect(CubiChannel.plain("\u{202E}abc\u{2028}d", limit: limit, fallback: "x") == "abcd")
    #expect(CubiChannel.plain("  a \t  b  ", limit: limit, fallback: "x") == "a b")
    // Nothing visible left: the fallback.
    for blank in ["", "   ", "\u{200B}", "\u{3164}", "\n\u{202E}"] {
        #expect(CubiChannel.plain(blank, limit: limit, fallback: "x") == "x")
    }
    // At most `limit` characters, and at most 4 × limit scalars however few characters.
    #expect(CubiChannel.plain(String(repeating: "名", count: limit + 5), limit: limit, fallback: "x") == String(repeating: "名", count: limit))
    let zalgo = CubiChannel.plain("a" + String(repeating: "\u{0301}", count: limit * 8), limit: limit, fallback: "x")
    #expect(zalgo.unicodeScalars.count <= limit * 4)
    // What Cubi accepts stays as it is.
    for fine in ["👨‍👩‍👧", "🙂 Mac", "alpha 的 MacBook Pro"] {
        #expect(CubiChannel.plain(fine, limit: limit, fallback: "x") == fine)
    }
}

@Test func eventsAreOneJSONObjectPerLine() {
    let sink = Sink()
    let channel = CubiChannel(output: sink.write)
    channel.log("ready\nnow")
    channel.state(["peers": [["id": "LANNudge-0", "name": "alpha"]]])
    channel.reply(id: 3, ok: true, out: ["result": "已觸發"])
    let lines = sink.lines
    #expect(lines.count == 3)
    #expect(lines[0]["type"] as? String == "log" && lines[0]["text"] as? String == "readynow")
    #expect(lines[1]["type"] as? String == "state" && (lines[1]["data"] as? [String: Any])?["peers"] != nil)
    #expect(lines[2]["type"] as? String == "reply" && lines[2]["id"] as? Int == 3 && lines[2]["ok"] as? Bool == true)
}

@Test func presentWaitsForCubisAnswerAndNotLonger() {
    let sink = Sink()
    let channel = CubiChannel(output: sink.write)
    // Cubi answers ok: shown.
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
        let id = sink.lines.last?["id"] as? Int ?? -1
        _ = channel.take(Data(#"{"id":\#(id),"ok":true,"type":"presented"}"#.utf8))
    }
    #expect(channel.present(effect: "knock", from: "\u{202E}alpha", windowShaken: false))
    let sent = sink.lines.last
    #expect(sent?["type"] as? String == "present" && sent?["from"] as? String == "alpha" && sent?["effect"] as? String == "knock")

    // Cubi says busy: not shown.
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
        let id = sink.lines.last?["id"] as? Int ?? -1
        _ = channel.take(Data(#"{"id":\#(id),"ok":false,"reason":"busy","type":"presented"}"#.utf8))
    }
    #expect(!channel.present(effect: "zap", from: "alpha", windowShaken: false))

    // No answer: not shown, after the wait and not much more.
    let began = Date()
    #expect(!channel.present(effect: "shake", from: "alpha", windowShaken: false))
    let waited = Date().timeIntervalSince(began)
    #expect(waited >= CubiChannel.presentWait - 0.05 && waited < CubiChannel.presentWait + 1)
}

@Test func cubisLinesAreReadAndAnythingElseIgnored() {
    let channel = CubiChannel(output: { _ in })
    #expect(channel.take(Data(#"{"action":"send","args":{"effect":"zap","peer":"LANNudge-0"},"id":4,"type":"call"}"#.utf8))
            == CubiChannel.Call(id: 4, action: "send", args: ["effect": "zap", "peer": "LANNudge-0"]))
    #expect(channel.take(Data(#"{"action":"send","id":true,"type":"call"}"#.utf8)) == nil)
    #expect(channel.take(Data(#"{"protocol":1,"type":"hello"}"#.utf8)) == nil)
    // An answer nobody waits for changes nothing.
    #expect(channel.take(Data(#"{"id":99,"ok":true,"type":"presented"}"#.utf8)) == nil)
    #expect(channel.take(Data("not json".utf8)) == nil)
}
