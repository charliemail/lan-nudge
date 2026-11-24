import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LANNudge

struct DesktopPetTests {
    private func gif(frames: Int, delay: Double) throws -> NSImage {
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil))
        let ctx = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let frame = try #require(ctx.makeImage())
        let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
        for _ in 0..<frames { CGImageDestinationAddImage(dest, frame, props) }
        #expect(CGImageDestinationFinalize(dest))
        return try #require(NSImage(data: data as Data))
    }

    @Test func playDurationIsOneLoopClamped() throws {
        #expect(abs(DesktopPet.playDuration(of: try gif(frames: 3, delay: 0.5)) - 1.5) < 0.01)
        #expect(DesktopPet.playDuration(of: try gif(frames: 2, delay: 0.1)) == 1)
        #expect(DesktopPet.playDuration(of: try gif(frames: 4, delay: 3)) == 5)
    }

    @Test(arguments: ["Pet-idle", "Pet-shock"])
    func bundledDefaultLoadsAndAnimates(_ name: String) throws {
        let url = try #require(Bundle.main.url(forResource: name, withExtension: "gif"))
        let image = try #require(NSImage(contentsOf: url))
        #expect(DesktopPet.playDuration(of: image) > 1.2)
    }
}
