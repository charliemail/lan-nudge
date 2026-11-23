import AppKit
import CoreGraphics

// Usage: make-app-icon <source> <out-1024.png>
// Background = transparent or near-white pixels connected to the image corners (flood fill), so the
// cut follows the artwork's own rounded corners. The body is placed on the macOS icon grid:
// 824x824 on a 1024 canvas. Adapted from lan-listening-room, whose artwork sat on black instead.
let args = CommandLine.arguments
guard let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("cannot read") }
let w = cg.width, h = cg.height
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
func isBackground(_ i: Int) -> Bool {
    let alpha = Int(px[i * 4 + 3])
    let lum = Int(px[i * 4]) + Int(px[i * 4 + 1]) + Int(px[i * 4 + 2])
    // The body's edge is near-black, so a high cut-off separates it cleanly from a white or soft-gray surround.
    return alpha < 24 || lum >= 600
}

var isBG = [Bool](repeating: false, count: w * h)
var stack = [0, w - 1, (h - 1) * w, h * w - 1]
while let i = stack.popLast() {
    guard !isBG[i], isBackground(i) else { continue }
    isBG[i] = true
    let x = i % w, y = i / w
    if x > 0 { stack.append(i - 1) }
    if x < w - 1 { stack.append(i + 1) }
    if y > 0 { stack.append(i - w) }
    if y < h - 1 { stack.append(i + w) }
}

var minX = w, maxX = 0, minY = h, maxY = 0, bgCount = 0
for i in 0..<(w * h) {
    if isBG[i] {
        px[i * 4] = 0; px[i * 4 + 1] = 0; px[i * 4 + 2] = 0; px[i * 4 + 3] = 0
        bgCount += 1
        continue
    }
    let x = i % w, y = i / w
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    // Soften the 1px rim next to the background (an anti-aliased blend with the surround).
    let touches = (x > 0 && isBG[i - 1]) || (x < w - 1 && isBG[i + 1]) || (y > 0 && isBG[i - w]) || (y < h - 1 && isBG[i + w])
    if touches {
        for c in 0..<4 { px[i * 4 + c] = UInt8(Double(px[i * 4 + c]) * 0.5) }
    }
}
print("background pixels: \(bgCount) (\(String(format: "%.1f", Double(bgCount) / Double(w * h) * 100))%), body bbox x[\(minX),\(maxX)] y[\(minY),\(maxY)]")

let masked = ctx.makeImage()!
let size = 1024, bodySize = 824.0, margin = (Double(size) - bodySize) / 2
let out = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
out.interpolationQuality = .high
let bodyW = Double(maxX - minX + 1), bodyH = Double(maxY - minY + 1)
let scale = bodySize / max(bodyW, bodyH)
// CG y is bottom-up; minY above is a top-down row index.
let bodyBottom = Double(h - 1 - maxY)
out.draw(masked, in: CGRect(x: margin - Double(minX) * scale, y: margin - bodyBottom * scale,
                            width: Double(w) * scale, height: Double(h) * scale))
let rep = NSBitmapImageRep(cgImage: out.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2])")
