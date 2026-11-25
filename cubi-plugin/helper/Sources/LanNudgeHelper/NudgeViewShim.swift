import Foundation

/// The one piece of the app's NudgeView that its WindowShaker (symlinked here) uses: the shake's
/// offset over time, with the app's own numbers. The view itself is the app's and is not built here.
enum NudgeView {
    nonisolated static func shakeOffset(_ t: Double) -> CGFloat {
        let decay = max(0, 1 - t / 1.1)
        return CGFloat(sin(t * 2 * .pi * 9) * 16 * decay)
    }
}
