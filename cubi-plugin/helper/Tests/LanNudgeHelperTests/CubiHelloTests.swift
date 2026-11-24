import Foundation
import Testing
@testable import LanNudgeHelper

// Inputs: Cubi's hello as its ServiceProtocol.hello() writes it (Cubi commit 173f75b), Cubi's `call`
// line from the same file, and variations derived from them or from CubiHello's own constants.

private let cubiHello = #"{"protocol":1,"type":"hello"}"#
private func data(_ s: String) -> Data { Data(s.utf8) }

@Test func onlyCubisExactHelloIsAccepted() {
    #expect(CubiHello.accepts(data(cubiHello)))
    // Key order and spacing do not matter; JSON is JSON.
    #expect(CubiHello.accepts(data(#"{ "type": "hello", "protocol": 1 }"#)))

    // Another protocol, or something that only looks like it.
    #expect(!CubiHello.accepts(data(#"{"protocol":2,"type":"hello"}"#)))
    #expect(!CubiHello.accepts(data(#"{"protocol":true,"type":"hello"}"#)))
    #expect(!CubiHello.accepts(data(#"{"protocol":1.5,"type":"hello"}"#)))
    #expect(!CubiHello.accepts(data(#"{"protocol":"1","type":"hello"}"#)))
    #expect(!CubiHello.accepts(data(#"{"type":"hello"}"#)))
    // Any other line Cubi writes, or a hook's JSON input, is not a hello.
    #expect(!CubiHello.accepts(data(#"{"action":"send","id":3,"type":"call"}"#)))
    #expect(!CubiHello.accepts(data(#"{"protocol":1,"type":"Hello"}"#)))
    #expect(!CubiHello.accepts(data("")))
    #expect(!CubiHello.accepts(data(String(cubiHello.dropLast()))))
    // Too long to be a first line.
    let padded = cubiHello.dropLast() + String(repeating: " ", count: CubiHello.lineLimit) + "}"
    #expect(!CubiHello.accepts(data(String(padded))))
}

@Test func theFirstLineIsReadUpToItsNewlineOrNotAtAll() throws {
    func first(_ input: String, closing: Bool = true, timeout: TimeInterval = 1) -> Data? {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(data(input))
        if closing { try? pipe.fileHandleForWriting.close() }
        return CubiHello.readFirstLine(from: pipe.fileHandleForReading, timeout: timeout)
    }
    #expect(first(cubiHello + "\n" + cubiHello + "\n") == data(cubiHello))
    // No newline before the end, or before the time is up: nothing.
    #expect(first(cubiHello) == nil)
    #expect(first(cubiHello, closing: false, timeout: 0.2) == nil)
    // A first line longer than the limit is not read to its end.
    #expect(first(String(repeating: " ", count: CubiHello.lineLimit + 1) + "\n") == nil)
}
