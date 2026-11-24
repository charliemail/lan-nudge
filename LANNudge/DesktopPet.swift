import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Character that idles on the desktop and plays a "shocked" GIF on any nudge.
/// Default GIFs ship in the bundle (Pet-idle.gif / Pet-shock.gif); a GIF the user picks is copied
/// into Application Support and takes precedence.
@MainActor @Observable
final class DesktopPet {
    enum Pose: String, CaseIterable {
        case idle, shock
        var title: String { self == .idle ? "待機圖" : "被電擊圖" }
    }

    static let height: CGFloat = 180
    /// Room for the sender line plus a 60-character message wrapped to three lines.
    static let captionHeight: CGFloat = 100
    static let minWidth: CGFloat = 260

    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "petEnabled"); refresh() }
    }
    private(set) var hasImages = false
    private(set) var customPoses: Set<Pose> = []
    private(set) var isShocking = false
    private(set) var error: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let autosaveName: String
    @ObservationIgnored private var images: [Pose: NSImage] = [:]
    @ObservationIgnored private var panel: PetPanel?

    init(defaults: UserDefaults, instance: String?) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "petEnabled") as? Bool ?? true
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appending(path: "LAN Nudge/Pet" + (instance.map { "-\($0)" } ?? ""))
        autosaveName = "DesktopPet" + (instance ?? "")
        refresh()
    }

    /// Asks for a GIF and copies it in, so moving or deleting the original doesn't break the pet.
    func choose(_ pose: Pose) {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.gif]
        open.message = "選擇\(pose.title)（GIF）"
        guard open.runModal() == .OK, let source = open.url else { return }
        guard NSImage(contentsOf: source)?.isValid == true else {
            error = "讀不到這張 GIF：\(source.lastPathComponent)"
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = customURL(pose)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
            error = nil
        } catch {
            self.error = "無法儲存圖片：\(error.localizedDescription)"
        }
        refresh()
    }

    /// One loop of the shock GIF, or nil when the pet can't react here (turned off, or not on the
    /// current Space, e.g. a full-screen app), so the caller falls back to the overlay.
    var shockLoop: Double? {
        guard let panel, panel.isOnActiveSpace, !isShocking, let shock = images[.shock] else { return nil }
        return Self.playDuration(of: shock)
    }

    /// Shock pose for `animateFor` seconds, then idle again while the caption stays up to `showFor`.
    func shock(_ caption: PetCaption.Content, animateFor: Double, showFor: Double) -> Bool {
        guard shockLoop != nil, let panel, let shock = images[.shock], let idle = images[.idle] else { return false }
        isShocking = true
        panel.setImage(shock)
        panel.setCaption(caption)
        Sounds.play(.cartoonShock)
        Task {
            try? await Task.sleep(for: .seconds(animateFor))
            panel.setImage(idle)
            try? await Task.sleep(for: .seconds(max(showFor - animateFor, 0)))
            panel.setCaption(nil)
            isShocking = false
        }
        return true
    }

    /// One full loop of the GIF, clamped so a long GIF can't hold the screen for long.
    nonisolated static func playDuration(of image: NSImage) -> Double {
        guard let rep = image.representations.first as? NSBitmapImageRep,
              let frames = rep.value(forProperty: .frameCount) as? Int, frames > 1 else { return 2 }
        let total = (0..<frames).reduce(0.0) { sum, i in
            rep.setProperty(.currentFrame, withValue: i)
            return sum + ((rep.value(forProperty: .currentFrameDuration) as? Double) ?? 0.1)
        }
        rep.setProperty(.currentFrame, withValue: 0)
        return min(max(total, 1), 5)
    }

    func restoreDefault(_ pose: Pose) {
        try? FileManager.default.removeItem(at: customURL(pose))
        refresh()
    }

    private func customURL(_ pose: Pose) -> URL { directory.appending(path: "\(pose.rawValue).gif") }

    private func refresh() {
        customPoses = Set(Pose.allCases.filter { FileManager.default.fileExists(atPath: customURL($0).path) })
        images = Dictionary(uniqueKeysWithValues: Pose.allCases.compactMap { pose in
            let url = customPoses.contains(pose) ? customURL(pose)
                : Bundle.main.url(forResource: "Pet-\(pose.rawValue)", withExtension: "gif")
            return url.flatMap(NSImage.init(contentsOf:)).map { (pose, $0) }
        })
        hasImages = images.count == Pose.allCases.count
        guard enabled, hasImages, let idle = images[.idle] else {
            panel?.orderOut(nil)
            panel = nil
            return
        }
        let panel = self.panel ?? PetPanel(autosaveName: autosaveName)
        if !isShocking { panel.setImage(idle) }
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

/// Floats above windows on every Space except full-screen ones. Unlike the overlay it takes mouse
/// clicks so it can be dragged; the window server still passes clicks through fully transparent pixels.
private final class PetPanel: NSPanel {
    private let imageView = DraggableImageView()
    private let caption = NSHostingView(rootView: PetCaption(content: .init(sender: "", message: nil, waiting: 0)))

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

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
    func setImage(_ image: NSImage) {
        let width = (DesktopPet.height * image.size.width / max(image.size.height, 1)).rounded()
        let size = CGSize(width: max(width, DesktopPet.minWidth), height: DesktopPet.height + DesktopPet.captionHeight)
        if frame.size != size {
            setFrame(CGRect(x: frame.midX - size.width / 2, y: frame.minY, width: size.width, height: size.height), display: true)
        }
        imageView.frame = CGRect(x: 0, y: DesktopPet.captionHeight, width: size.width, height: DesktopPet.height)
        caption.frame = CGRect(x: 0, y: 0, width: size.width, height: DesktopPet.captionHeight)
        imageView.image = image
    }

    func setCaption(_ content: PetCaption.Content?) {
        if let content { caption.rootView = PetCaption(content: content) }
        caption.isHidden = content == nil
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class DraggableImageView: NSImageView {
    override var mouseDownCanMoveWindow: Bool { true }
}

struct PetCaption: View {
    struct Content: Equatable {
        let sender: String
        let message: String?
        /// Nudges still queued behind this one.
        let waiting: Int
    }

    let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").foregroundStyle(.yellow)
                Text("\(content.sender) 戳了你一下").font(.headline).lineLimit(1)
                if content.waiting > 0 {
                    Text("還有 \(content.waiting) 則").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = content.message {
                Text(message).font(.body).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
