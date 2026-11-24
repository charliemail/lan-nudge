import Foundation

/// Cubi's first line to a plugin service: `{"type":"hello","protocol":1}`. The helper does nothing
/// until it reads exactly that, so it only ever runs under a Cubi that started it on purpose (not
/// from a panel, a hook, or a terminal), and under one that speaks this protocol.
enum CubiHello {
    static let protocolVersion = 1
    static let timeout: TimeInterval = 5
    /// A first line longer than this is not a hello.
    static let lineLimit = 1024

    enum Greeting: Equatable {
        case accepted
        /// A hello for another protocol: this helper cannot talk to that Cubi, and starting it again
        /// will not change that, so it ends with 0 (Cubi does not restart a service that exits 0).
        case otherProtocol(Int)
        case notHello
    }

    private struct Line: Decodable {
        let type: String
        let `protocol`: Int
    }

    static func greeting(_ line: Data) -> Greeting {
        guard line.count <= lineLimit, let hello = try? JSONDecoder().decode(Line.self, from: line),
              hello.type == "hello" else { return .notHello }
        return hello.protocol == protocolVersion ? .accepted : .otherProtocol(hello.protocol)
    }

    static func accepts(_ line: Data) -> Bool { greeting(line) == .accepted }

    /// Reads stdin up to the first newline, within `timeout`; nil when nothing complete came.
    static func readFirstLine(from handle: FileHandle = .standardInput, timeout: TimeInterval = timeout) -> Data? {
        final class Box: @unchecked Sendable { var line: Data? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var buffer = Data()
            while buffer.count <= lineLimit {
                let chunk = handle.readData(ofLength: 1)
                if chunk.isEmpty { break }
                if chunk[chunk.startIndex] == 0x0a { box.line = buffer; break }
                buffer.append(chunk)
            }
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success ? box.line : nil
    }
}
