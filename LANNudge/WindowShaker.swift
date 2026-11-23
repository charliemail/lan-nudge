import AppKit
import ApplicationServices

/// MSN-style nudge: shakes the receiver's focused window of the frontmost app via the
/// Accessibility API. Needs the Accessibility permission (and no App Sandbox).
@MainActor
enum WindowShaker {
    static let seconds = 1.1

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to System Settings → Privacy & Security → Accessibility.
    static func requestPermission() {
        // String value of kAXTrustedCheckOptionPrompt; the imported global isn't concurrency-safe in Swift 6.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// False when it can't shake (no permission, no window, full screen, app refuses to move it);
    /// the caller then keeps the in-overlay shake only. The window always ends at its original spot.
    static func shakeFrontWindow() -> Bool {
        guard isTrusted,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let window = focusedWindow(of: pid),
              !isFullScreen(window),
              let origin = position(of: window),
              setPosition(window, origin) else { return false }

        Task {
            let start = ContinuousClock.now
            while true {
                let t = (ContinuousClock.now - start) / .seconds(1)
                guard t < seconds,
                      setPosition(window, CGPoint(x: origin.x + NudgeView.shakeOffset(t), y: origin.y)) else { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
            _ = setPosition(window, origin)
        }
        return true
    }

    private static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        // A hung app would otherwise block the main thread for the default 6 s per call.
        AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = value as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.2)
        return window
    }

    private static func isFullScreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success
            && (value as? Bool) == true
    }

    private static func position(of window: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func setPosition(_ window: AXUIElement, _ point: CGPoint) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }
}
