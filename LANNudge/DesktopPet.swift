import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Character that idles on the desktop, plays a "shocked" GIF on any nudge and a read-receipt GIF
/// when a nudge the user sent is read. Default GIFs ship in the bundle (Pet-idle/-shock/-read.gif);
/// a GIF the user picks is copied into Application Support and takes precedence.
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

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let autosaveName: String
    @ObservationIgnored private var images: [Pose: NSImage] = [:]
    @ObservationIgnored private var panel: PetPanel?
    @ObservationIgnored private var shockTask: Task<Void, Never>?

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
        let loop = Self.playDuration(of: image)
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
        hasImages = images[.idle] != nil && images[.shock] != nil
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
    private let caption = CaptionHostingView(rootView: PetCaption(card: nil, title: "", symbol: ""))

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

    func setCaption(_ card: NudgeCard?, title: String = "", symbol: String = "") {
        if let card { caption.rootView = PetCaption(card: card, title: title, symbol: symbol) }
        caption.isHidden = card == nil
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class DraggableImageView: NSImageView {
    override var mouseDownCanMoveWindow: Bool { true }
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
