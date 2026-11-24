// swift-tools-version:6.0
// LAN Nudge's helper for the Cubi plugin. It compiles the app's own Protocol, Identity, PeerNetwork
// and ReceiveGate through the symlinks in Sources/LanNudgeHelper, so both speak the same wire format.
// Versions are pinned to what the app resolves (LANNudge.xcodeproj's Package.resolved); this
// package's own Package.resolved is not committed.
import PackageDescription

let package = Package(
    name: "LanNudgeHelper",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates", exact: "1.21.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.1.2"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.7.4"),
    ],
    targets: [
        .executableTarget(
            name: "LanNudgeHelper",
            dependencies: [
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ],
            linkerSettings: [
                // Its own Info.plist (bundle ID, local network usage, Bonjour type) inside the
                // executable. Cubi starts it with responsibility disclaimed, so it is its own
                // responsible process (seen in a probe); whether macOS then reads this Info.plist for
                // the local network prompt is not known yet and is checked on a real Mac.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", Context.packageDirectory + "/Info.plist"]),
            ]
        ),
        .testTarget(name: "LanNudgeHelperTests", dependencies: ["LanNudgeHelper"]),
    ]
)
