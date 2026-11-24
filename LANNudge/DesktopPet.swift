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
    static let captionHeight: CGFloat = 44

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

    /// Plays the shock pose instead of the overlay. False when the pet isn't on the current
    /// Space (e.g. a full-screen app), so the caller can fall back to the overlay.
    func shock(from sender: String) -> Bool {
        guard let panel, panel.isOnActiveSpace, !isShocking, let shock = images[.shock] else { return false }
        isShocking = true
        panel.show(shock, caption: "\(sender) 戳了你一下")
        Sounds.play(.cartoonShock)
        Task {
            try? await Task.sleep(for: .seconds(Self.playDuration(of: shock)))
            isShocking = false
            if let idle = images[.idle] { self.panel?.show(idle, caption: nil) }
        }
        return true
    }

    /// One full loop of the GIF, clamped so a long GIF can't hold the "busy" slot (no queue) for long.
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
        panel.show(idle, caption: nil)
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

/// Floats above windows on every Space except full-screen ones. Unlike the overlay it takes mouse
/// clicks so it can be dragged; the window server still passes clicks through fully transparent pixels.
private final class PetPanel: NSPanel {
    private let imageView = DraggableImageView()
    private let caption = NSHostingView(rootView: PetCaption(text: ""))

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
            setFrame(OverlayController.frame(size: CGSize(width: 140, height: DesktopPet.height + DesktopPet.captionHeight),
                                             in: visible), display: false)
        }
        setFrameAutosaveName(autosaveName)
    }

    /// Sized from the idle GIF's aspect ratio; the caption strip sits under the character.
    func show(_ image: NSImage, caption text: String?) {
        let width = (DesktopPet.height * image.size.width / max(image.size.height, 1)).rounded()
        let size = CGSize(width: max(width, 220), height: DesktopPet.height + DesktopPet.captionHeight)
        if frame.size != size {
            setFrame(CGRect(x: frame.midX - size.width / 2, y: frame.minY, width: size.width, height: size.height), display: true)
        }
        imageView.frame = CGRect(x: 0, y: DesktopPet.captionHeight, width: size.width, height: DesktopPet.height)
        caption.frame = CGRect(x: 0, y: 0, width: size.width, height: DesktopPet.captionHeight)
        imageView.image = image
        caption.rootView = PetCaption(text: text ?? "")
        caption.isHidden = text == nil
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class DraggableImageView: NSImageView {
    override var mouseDownCanMoveWindow: Bool { true }
}

private struct PetCaption: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill").foregroundStyle(.yellow)
            Text(text).font(.headline).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
