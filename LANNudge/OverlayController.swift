import AppKit
import SwiftUI

@MainActor
final class OverlayController {
    static let shared = OverlayController()
    /// Tall enough for a three-line message and the 確認 button under the animation; the panel is
    /// transparent and, unless the nudge waits for 確認, click-through.
    static let panelSize = CGSize(width: 300, height: 300)
    /// Default without a message. Longer than the spec's ~1 s: at 1.2 s the shock was gone before
    /// people noticed it.
    static let defaultDuration = 2.0

    private var panel: NSPanel?
    private var timer: Task<Void, Never>?
    var isShowing: Bool { panel != nil }

    /// Returns false when another overlay is still on screen. `duration` nil: stays until `hide()`.
    @discardableResult
    func show(_ effect: Effect, card: NudgeCard, animateFor: Double, duration: Double?) -> Bool {
        guard panel == nil else { return false }
        let screens = NSScreen.screens.map { (frame: $0.frame, visible: $0.visibleFrame) }
        guard let visible = Self.visibleFrame(for: NSEvent.mouseLocation, screens: screens) else { return false }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let panel = OverlayPanel(contentRect: Self.frame(size: Self.panelSize, in: visible))
        panel.ignoresMouseEvents = card.confirm == nil
        panel.contentView = FirstClickHostingView(rootView: NudgeView(effect: effect, card: card, animateFor: animateFor,
                                                                        reduceMotion: reduceMotion))
        panel.orderFrontRegardless()
        Sounds.play(effect)
        // The overlay label still names the sender; the real window shake is best-effort on top.
        if effect == .shake, !reduceMotion { _ = WindowShaker.shakeFrontWindow() }
        self.panel = panel

        if let duration {
            timer = Task {
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                hide()
            }
        }
        return true
    }

    func hide() {
        timer?.cancel()
        timer = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    /// Screen under the mouse; falls back to the primary screen (index 0), not `NSScreen.main`,
    /// because `main` means "screen with the key window", which an accessory app rarely owns.
    nonisolated static func visibleFrame(for point: CGPoint, screens: [(frame: CGRect, visible: CGRect)]) -> CGRect? {
        (screens.first { $0.frame.contains(point) } ?? screens.first)?.visible
    }

    nonisolated static func frame(size: CGSize, in visible: CGRect, margin: CGFloat = 16) -> CGRect {
        CGRect(x: visible.maxX - size.width - margin, y: visible.minY + margin,
               width: size.width, height: size.height)
    }
}

/// The panels never become key, so without this the first click on 確認 would only be taken as
/// bringing the window forward.
class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Transparent panel that never takes key/main status, so the user's current app keeps keyboard
/// focus; click-through unless it shows a 確認 button.
private final class OverlayPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        // NSPanel defaults to true; an LSUIElement app is never active, so it would hide immediately.
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
