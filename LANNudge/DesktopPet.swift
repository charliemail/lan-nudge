import AppKit
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Character that idles on the desktop, plays a "shocked" animation on any nudge and a read-receipt
/// animation when a nudge the user sent is read. Default GIFs ship in the bundle
/// (Pet-idle/-shock/-read.gif); a GIF or WebP the user picks is copied into Application Support and
/// takes precedence.
@MainActor @Observable
final class DesktopPet {
    enum Pose: String, CaseIterable {
        case idle, shock, read
        var title: String {
            switch self {
            case .idle: "待機圖"
            case .shock: "被電擊圖"
            case .read: "已讀回條圖"
            }
        }
    }

    static let height: CGFloat = 180
    /// Room for the sender line, a 60-character message wrapped to three lines, and the 確認 button.
    static let captionHeight: CGFloat = 140
    static let minWidth: CGFloat = 260

    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "petEnabled"); refresh() }
    }
    private(set) var hasImages = false
    private(set) var customPoses: Set<Pose> = []
    private(set) var isShocking = false
    private(set) var error: String?
    /// Poses whose chosen image is still being converted.
    private(set) var converting: Set<Pose> = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let autosaveName: String
    @ObservationIgnored private var images: [Pose: PetAnimation] = [:]
    @ObservationIgnored private var panel: PetPanel?
    @ObservationIgnored private var shockTask: Task<Void, Never>?
    /// Double-clicking the character (not its caption) opens the control panel.
    @ObservationIgnored var onDoubleClick: (() -> Void)?

    init(defaults: UserDefaults, instance: String?) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "petEnabled") as? Bool ?? true
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appending(path: "LAN Nudge/Pet" + (instance.map { "-\($0)" } ?? ""))
        autosaveName = "DesktopPet" + (instance ?? "")
        refresh()
    }

    /// Asks for a GIF or WebP and stores it as a pet-sized APNG, so moving or deleting the original
    /// doesn't break the pet and later launches decode it fast: ImageIO redecodes an animated WebP
    /// from its first frame for every frame (seconds for a long one), an APNG in a blink. The slow
    /// first decode runs off the main thread.
    func choose(_ pose: Pose) {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.gif, .webP]
        open.message = "選擇\(pose.title)（GIF 或 WebP）"
        guard open.runModal() == .OK, let source = open.url else { return }
        converting.insert(pose)
        Task {
            let png = await Task.detached(priority: .userInitiated) { PetAnimation(url: source)?.pngData() }.value
            converting.remove(pose)
            guard let png else {
                error = "讀不到這張圖，或動畫太大（尺寸 × 格數過多）：\(source.lastPathComponent)"
                return
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                removeCustom(pose)
                try png.write(to: directory.appending(path: "\(pose.rawValue).png"))
                error = nil
            } catch {
                self.error = "無法儲存圖片：\(error.localizedDescription)"
            }
            refresh()
        }
    }

    /// One loop of the shock GIF, or nil when the pet can't react here (turned off, or not on the
    /// current Space, e.g. a full-screen app), so the caller falls back to the overlay.
    var shockLoop: Double? {
        guard let panel, panel.isOnActiveSpace, !isShocking, let shock = images[.shock] else { return nil }
        return shock.playDuration
    }

    /// Shock pose for `animateFor` seconds, then idle again while the caption stays up to `showFor`
    /// (nil: until `dismiss()`).
    func shock(_ card: NudgeCard, animateFor: Double, showFor: Double?) -> Bool {
        guard shockLoop != nil, let panel, let shock = images[.shock], let idle = images[.idle] else { return false }
        isShocking = true
        panel.setImage(shock)
        panel.setCaption(card, title: "\(card.sender) 戳了你一下", symbol: "bolt.fill")
        Sounds.play(.cartoonShock)
        shockTask = Task {
            try? await Task.sleep(for: .seconds(animateFor))
            guard !Task.isCancelled else { return }
            panel.setImage(idle)
            guard let showFor else { return }
            try? await Task.sleep(for: .seconds(max(showFor - animateFor, 0)))
            guard !Task.isCancelled else { return }
            dismiss()
        }
        return true
    }

    /// The read-receipt GIF with `text` under it; false when the pet can't show it (turned off, busy
    /// with a nudge, not on this Space) so the caller shows a notice instead.
    func read(_ text: String) -> Bool {
        guard let panel, panel.isOnActiveSpace, !isShocking, let image = images[.read] else { return false }
        isShocking = true
        panel.setImage(image)
        panel.setCaption(NudgeCard(sender: "", message: nil, unread: { 0 }, confirm: nil), title: text, symbol: "checkmark.circle.fill")
        let loop = image.playDuration
        shockTask = Task {
            try? await Task.sleep(for: .seconds(max(loop, 2)))
            guard !Task.isCancelled else { return }
            dismiss()
        }
        return true
    }

    func dismiss() {
        shockTask?.cancel()
        shockTask = nil
        guard isShocking else { return }
        if let idle = images[.idle] { panel?.setImage(idle) }
        panel?.setCaption(nil)
        isShocking = false
    }

    func restoreDefault(_ pose: Pose) {
        removeCustom(pose)
        refresh()
    }

    /// png: what `choose` stores; gif and webp: copies of the original kept by earlier versions.
    private func customURLs(_ pose: Pose) -> [URL] {
        ["png", "gif", "webp"].map { directory.appending(path: "\(pose.rawValue).\($0)") }
    }

    private func customURL(_ pose: Pose) -> URL? { customURLs(pose).first { FileManager.default.fileExists(atPath: $0.path) } }

    private func removeCustom(_ pose: Pose) {
        for url in customURLs(pose) { try? FileManager.default.removeItem(at: url) }
    }

    private func refresh() {
        customPoses = Set(Pose.allCases.filter { customURL($0) != nil })
        images = Dictionary(uniqueKeysWithValues: Pose.allCases.compactMap { pose in
            let url = customURL(pose) ?? Bundle.main.url(forResource: "Pet-\(pose.rawValue)", withExtension: "gif")
            return url.flatMap { PetAnimation(url: $0) }.map { (pose, $0) }
        })
        hasImages = images[.idle] != nil && images[.shock] != nil
        guard enabled, hasImages, let idle = images[.idle] else {
            panel?.orderOut(nil)
            panel = nil
            return
        }
        let panel = self.panel ?? PetPanel(autosaveName: autosaveName)
        panel.onDoubleClick = { [weak self] in self?.onDoubleClick?() }
        if !isShocking { panel.setImage(idle) }
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

/// Floats above windows on every Space except full-screen ones. Unlike the overlay it takes mouse
/// clicks so it can be dragged; the window server still passes clicks through fully transparent pixels.
private final class PetPanel: NSPanel {
    private let imageView = PetImageView()
    private let caption = CaptionHostingView(rootView: PetCaption(card: nil, title: "", symbol: ""))
    var onDoubleClick: (() -> Void)?

    init(autosaveName: String) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        caption.isHidden = true
        let container = NSView()
        container.addSubview(imageView)
        container.addSubview(caption)
        contentView = container

        // Default spot: bottom-right of the primary screen; a saved (dragged) position wins.
        if let visible = NSScreen.screens.first?.visibleFrame {
            setFrame(OverlayController.frame(size: CGSize(width: DesktopPet.minWidth, height: DesktopPet.height + DesktopPet.captionHeight),
                                             in: visible), display: false)
        }
        setFrameAutosaveName(autosaveName)
    }

    /// Sized from the image's aspect ratio; the caption strip sits under the character.
    func setImage(_ image: PetAnimation) {
        let width = (DesktopPet.height * image.aspectRatio).rounded()
        let size = CGSize(width: max(width, DesktopPet.minWidth), height: DesktopPet.height + DesktopPet.captionHeight)
        if frame.size != size {
            setFrame(CGRect(x: frame.midX - size.width / 2, y: frame.minY, width: size.width, height: size.height), display: true)
        }
        imageView.frame = CGRect(x: 0, y: DesktopPet.captionHeight, width: size.width, height: DesktopPet.height)
        caption.frame = CGRect(x: 0, y: 0, width: size.width, height: DesktopPet.captionHeight)
        imageView.play(image)
    }

    func setCaption(_ card: NudgeCard?, title: String = "", symbol: String = "") {
        if let card { caption.rootView = PetCaption(card: card, title: title, symbol: symbol) }
        caption.isHidden = card == nil
    }

    /// Caught here rather than in the image view: the view lets a mouse-down drag the window, and a
    /// window drag never hands the click to the view. The first click still drags; only the second
    /// of a double-click on the character is taken.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 2, let onDoubleClick,
           imageView.frame.contains(contentView?.convert(event.locationInWindow, from: nil) ?? .zero) {
            onDoubleClick()
            return
        }
        super.sendEvent(event)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Plays the frames itself: NSImageView only animates GIFs (NSBitmapImageRep has no frame count for
/// WebP). Layer-hosting, so AppKit never redraws over the layer's contents.
private final class PetImageView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        self.layer = layer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Restarts from the first frame; with Reduce Motion on, shows only that frame.
    func play(_ animation: PetAnimation) {
        guard let layer else { return }
        layer.removeAnimation(forKey: "frames")
        layer.contents = animation.frames[0]
        guard animation.frames.count > 1, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let frames = CAKeyframeAnimation(keyPath: "contents")
        frames.values = animation.frames
        frames.keyTimes = animation.keyTimes.map { NSNumber(value: $0) }
        frames.calculationMode = .discrete
        frames.duration = animation.loopDuration
        frames.repeatCount = .infinity
        layer.add(frames, forKey: "frames")
    }
}

/// Every frame of an animated GIF or WebP, decoded once by ImageIO (which also composites WebP
/// frames), scaled down to what the pet can show.
struct PetAnimation {
    /// The pet is 180 pt tall, so 400 px keeps square-ish art sharp on Retina.
    static let maxPixelSize = 400
    // ponytail: whole animation held in memory, refused past the cap; stream frames if longer art is needed.
    static let maxBytes = 96 << 20

    let frames: [CGImage]
    let delays: [Double]

    init?(url: URL, maxPixelSize: Int = maxPixelSize, maxBytes: Int = maxBytes) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        self.init(source: source, maxPixelSize: maxPixelSize, maxBytes: maxBytes)
    }

    init?(data: Data, maxPixelSize: Int = maxPixelSize, maxBytes: Int = maxBytes) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        self.init(source: source, maxPixelSize: maxPixelSize, maxBytes: maxBytes)
    }

    private init?(source: CGImageSource, maxPixelSize: Int, maxBytes: Int) {
        let count = CGImageSourceGetCount(source)
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxPixelSize] as CFDictionary
        var frames: [CGImage] = []
        var delays: [Double] = []
        for index in 0..<count {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options),
                  frame.bytesPerRow * frame.height * count <= maxBytes else { return nil }
            frames.append(frame)
            delays.append(Self.delay(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]))
        }
        guard !frames.isEmpty else { return nil }
        self.frames = frames
        self.delays = delays
    }

    /// ImageIO's clamped delay, as browsers play it: a missing or near-zero delay means 0.1 s.
    private static func delay(_ properties: [CFString: Any]?) -> Double {
        let delay = [(kCGImagePropertyGIFDictionary, kCGImagePropertyGIFDelayTime),
                     (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPDelayTime),
                     (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGDelayTime)]
            .lazy.compactMap { (properties?[$0.0] as? [CFString: Any])?[$0.1] as? Double }.first
        return delay.map { $0 > 0.01 ? $0 : 0.1 } ?? 0.1
    }

    var aspectRatio: CGFloat { CGFloat(frames[0].width) / CGFloat(max(frames[0].height, 1)) }
    var loopDuration: Double { delays.reduce(0, +) }
    /// Start of each frame as a share of the loop, plus the closing 1 that `.discrete` needs.
    var keyTimes: [Double] { delays.reduce(into: [0]) { $0.append($0.last! + $1) }.map { $0 / loopDuration } }
    /// The frames as a looping APNG with the same delays.
    func pngData() -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, frames.count, nil) else { return nil }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
        for (frame, delay) in zip(frames, delays) {
            CGImageDestinationAddImage(dest, frame, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]] as CFDictionary)
        }
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// The frame on screen `seconds` after the start, looping.
    func frame(at seconds: Double) -> CGImage {
        let position = seconds.truncatingRemainder(dividingBy: loopDuration) / loopDuration
        return frames[min(keyTimes.lastIndex { $0 <= position } ?? 0, frames.count - 1)]
    }

    /// One full loop, clamped so a long animation can't hold the screen for long.
    var playDuration: Double { frames.count > 1 ? min(max(loopDuration, 1), 5) : 2 }
}

/// A transparent view drags the window when the panel is movable by its background; the caption
/// holds the 確認 button, so a click there must reach the button instead.
private final class CaptionHostingView: FirstClickHostingView<PetCaption> {
    override var mouseDownCanMoveWindow: Bool { false }
}

struct PetCaption: View {
    let card: NudgeCard?
    let title: String
    let symbol: String

    var body: some View {
        if let card {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: symbol).foregroundStyle(symbol == "bolt.fill" ? .yellow : .green).font(.headline)
                NudgeCardText(card: card, title: title)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .unreadBadge(card)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}
