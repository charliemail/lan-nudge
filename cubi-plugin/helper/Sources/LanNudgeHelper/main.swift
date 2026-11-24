import Foundation

// LAN Nudge as a Cubi plugin service. Cubi starts it, writes `hello` on stdin, and reads one JSON
// event per line on stdout. Without Cubi's hello it exits before touching the network.

guard let first = CubiHello.readFirstLine(), CubiHello.accepts(first) else {
    FileHandle.standardError.write(Data("lan-nudge helper: 沒有收到 Cubi 的 hello（protocol \(CubiHello.protocolVersion)），結束\n".utf8))
    exit(64)
}

print(#"{"text":"lan-nudge helper ready","type":"log"}"#)
fflush(stdout)

// Cubi closing stdin (quit, plugin off, or Cubi gone) is the signal to stop.
while !FileHandle.standardInput.availableData.isEmpty {}
exit(0)
