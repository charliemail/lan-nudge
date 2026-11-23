import SwiftUI

struct NudgeView: View {
    let effect: Effect
    let sender: String
    let reduceMotion: Bool
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            // t == 0 renders the static frame used for Reduce Motion.
            let t = reduceMotion ? 0 : context.date.timeIntervalSince(start)
            VStack(spacing: 8) {
                if effect == .cartoonShock { ShockGuy(t: t) }
                label.offset(x: effect == .shake ? Self.shakeOffset(t) : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 8)
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: effect == .shake ? "hand.point.right.fill" : "bolt.fill")
                .foregroundStyle(.yellow)
            Text("\(sender) 戳了你一下")
                .font(.headline)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 4)
    }

    /// ~9 Hz side-to-side, decaying to rest over the overlay's lifetime.
    nonisolated static func shakeOffset(_ t: Double) -> CGFloat {
        let decay = max(0, 1 - t / 1.1)
        return CGFloat(sin(t * 2 * .pi * 9) * 16 * decay)
    }
}

/// Original cartoon character: round head, spiky hair, X eyes, local sparks.
private struct ShockGuy: View {
    let t: Double

    var body: some View {
        // Sparks toggle at 3 Hz and stay small, well below photosensitive-flash thresholds.
        let sparksOn = t == 0 || Int(t * 6).isMultiple(of: 2)
        let jitter = CGFloat(sin(t * 2 * .pi * 12) * 3)

        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.blue)
                .frame(width: 34, height: 38)
                .offset(y: 44)

            ForEach(0..<7) { i in
                Capsule()
                    .fill(.black)
                    .frame(width: 3, height: 18)
                    .frame(height: 90, alignment: .top)
                    .rotationEffect(.degrees(Double(i - 3) * 20))
            }

            Circle()
                .fill(Color(red: 1, green: 0.86, blue: 0.62))
                .overlay(Circle().stroke(.black, lineWidth: 2))
                .frame(width: 56, height: 56)

            HStack(spacing: 14) {
                Text("✕")
                Text("✕")
            }
            .font(.system(size: 13, weight: .black))
            .offset(y: -5)

            Ellipse()
                .fill(.black)
                .frame(width: 14, height: 10)
                .offset(y: 13)

            ForEach([(-48.0, -14.0, -20.0), (48.0, 6.0, 25.0), (-40.0, 34.0, 10.0)], id: \.0) { x, y, angle in
                Image(systemName: "bolt.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.yellow)
                    .shadow(color: .orange, radius: 3)
                    .rotationEffect(.degrees(angle))
                    .offset(x: x, y: y)
                    .opacity(sparksOn ? 1 : 0.15)
            }
        }
        .frame(width: 130, height: 120)
        .offset(x: jitter)
    }
}
