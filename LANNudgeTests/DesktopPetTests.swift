import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LANNudge

struct DesktopPetTests {
    private func gif(frames: Int, delay: Double) throws -> PetAnimation {
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil))
        let ctx = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let frame = try #require(ctx.makeImage())
        let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
        for _ in 0..<frames { CGImageDestinationAddImage(dest, frame, props) }
        #expect(CGImageDestinationFinalize(dest))
        return try #require(PetAnimation(data: data as Data))
    }

    @Test func playDurationIsOneLoopClamped() throws {
        #expect(abs(try gif(frames: 3, delay: 0.5).playDuration - 1.5) < 0.01)
        #expect(try gif(frames: 2, delay: 0.1).playDuration == 1)
        #expect(try gif(frames: 4, delay: 3).playDuration == 5)
    }

    /// 3 frames (red, green, blue), 4×2 px, 500 ms each; made with img2webp. ImageIO can read WebP
    /// but not write it.
    @Test func animatedWebPPlaysEveryFrame() throws {
        let data = try #require(Data(base64Encoded: "UklGRrQAAABXRUJQVlA4WAoAAAACAAAAAwAAAQAAQU5JTQYAAAD/////AABBTk1GKAAAAAAAAAAAAAMAAAEAAPQBAAJWUDhMDwAAAC8DQAAABxDlj/4HIqL/AQBBTk1GKAAAAAAAAAAAAAMAAAEAAPQBAABWUDhMDwAAAC8DQAAAB9C/iP4HIqL/AQBBTk1GKAAAAAAAAAAAAAMAAAEAAPQBAABWUDhMDwAAAC8DQAAABxDR/v4HIqL/AQA="))
        let webp = try #require(PetAnimation(data: data))
        #expect(webp.frames.count == 3)
        #expect(webp.aspectRatio == 2)
        #expect(abs(webp.playDuration - 1.5) < 0.01)
        #expect(zip(webp.keyTimes, [0, 1.0 / 3, 2.0 / 3, 1]).allSatisfy { abs($0 - $1) < 0.001 })
    }

    @Test func oversizedAnimationIsRefused() throws {
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 3, nil))
        let ctx = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let frame = try #require(ctx.makeImage())
        for _ in 0..<3 { CGImageDestinationAddImage(dest, frame, nil) }
        #expect(CGImageDestinationFinalize(dest))
        #expect(PetAnimation(data: data as Data, maxBytes: 64 * 64 * 4 * 3) != nil)
        #expect(PetAnimation(data: data as Data, maxBytes: 64 * 64 * 4 * 3 - 1) == nil)
    }

    @Test(arguments: ["Pet-idle", "Pet-shock", "Pet-read"])
    func bundledDefaultLoadsAndAnimates(_ name: String) throws {
        let url = try #require(Bundle.main.url(forResource: name, withExtension: "gif"))
        let image = try #require(PetAnimation(url: url))
        #expect(image.frames.count > 1)
        #expect(image.frames.allSatisfy { max($0.width, $0.height) <= PetAnimation.maxPixelSize })
    }
}
