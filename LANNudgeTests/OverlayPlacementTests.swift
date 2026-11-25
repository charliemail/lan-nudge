import CoreGraphics
import Testing
@testable import LANNudge

struct OverlayPlacementTests {
    let primary = (frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                   visible: CGRect(x: 0, y: 80, width: 1440, height: 795))
    let secondary = (frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                     visible: CGRect(x: 1440, y: 0, width: 1920, height: 1055))

    @Test func picksScreenUnderMouse() {
        let v = OverlayController.visibleFrame(for: CGPoint(x: 2000, y: 500), screens: [primary, secondary])
        #expect(v == secondary.visible)
    }

    @Test func fallsBackToPrimaryWhenMouseOffScreen() {
        let v = OverlayController.visibleFrame(for: CGPoint(x: -500, y: -500), screens: [primary, secondary])
        #expect(v == primary.visible)
    }

    @Test func noScreensMeansNoFrame() {
        #expect(OverlayController.visibleFrame(for: .zero, screens: []) == nil)
    }

    @Test func bottomRightInsideVisibleFrameAboveDock() {
        let f = OverlayController.frame(size: CGSize(width: 280, height: 210), in: primary.visible)
        #expect(primary.visible.contains(f))
        #expect(f.maxX == primary.visible.maxX - 16)
        #expect(f.minY == primary.visible.minY + 16)
    }

    @Test func bigNudgeIsCenteredAndFitsTheScreen() {
        let size = OverlayController.bigSize(in: primary.visible)
        let f = OverlayController.centered(size: size, in: primary.visible)
        #expect(primary.visible.contains(f))
        #expect(abs(f.midX - primary.visible.midX) <= 1 && abs(f.midY - primary.visible.midY) <= 1)
        #expect(size.height == (primary.visible.height * OverlayController.bigShare).rounded())
        let scale = NudgeView.scale(toFit: size)
        #expect(scale > 2 && NudgeView.characterSize.height * scale <= size.height * 0.6 + 0.01)
    }

    @Test func shakeSettlesToRest() {
        #expect(NudgeView.shakeOffset(1.2) == 0)
    }
}
