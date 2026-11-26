import ImageIO
import SwiftUI

/// What a nudge's card says. `unread` is read live, so the count follows nudges that arrive while
/// it is up; `confirm` is set only when the nudge stays until 確認 is clicked.
struct NudgeCard {
    let sender: String
    let message: String?
    let unread: @MainActor () -> Int
    let confirm: (@MainActor () -> Void)?
}

/// The card's text, shared by the overlay and the desktop pet.
struct NudgeCardText: View {
    let card: NudgeCard
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.headline).lineLimit(1)
                if card.confirm == nil, card.unread() > 1 {
                    Text("還有 \(card.unread() - 1) 則").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = card.message {
                Text(message).font(.body).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            if let confirm = card.confirm {
                Button("確認", action: confirm).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

extension View {
    /// Unread count bubble on a sticky card, from 2 up (the one on screen counts).
    func unreadBadge(_ card: NudgeCard) -> some View {
        overlay(alignment: .topTrailing) {
            let count = card.unread()
            if card.confirm != nil, count >= 2 {
                Text("\(count)")
                    .font(.caption.bold())
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(.red, in: Capsule())
                    .offset(x: 6, y: -8)
            }
        }
    }
}

extension Effect {
    var tint: Color {
        switch self {
        case .cartoonShock, .shake: .yellow
        case .knock: .brown
        case .funnyFace: .pink
        }
    }
}

/// The effect's icon; 做鬼臉 uses the first frame of the author's character so it matches what the
/// receiver sees.
struct EffectIcon: View {
    let effect: Effect

    nonisolated static let face: CGImage? = Bundle.main.url(forResource: "Face", withExtension: "apng")
        .flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
        .flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                               kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) }

    var body: some View {
        if effect == .funnyFace, let face = Self.face {
            Image(decorative: face, scale: 1).resizable().scaledToFit().frame(width: 18, height: 18)
        } else {
            Image(systemName: effect.symbol).foregroundStyle(effect.tint)
        }
    }
}

struct NudgeView: View {
    let effect: Effect
    let card: NudgeCard
    /// After this the character leaves and only the card stays (with a message, or until 確認), so a
    /// big centered nudge doesn't keep covering the screen.
    let animateFor: Double
    let reduceMotion: Bool
    /// Size of the character over its drawn size (150 × 120); the card keeps its size.
    var scale: CGFloat = 1
    @State private var start = Date()
    @State private var settled = false
    /// Decoded per nudge (~0.1 s) and freed with the overlay rather than kept for the app's lifetime.
    private let face: PetAnimation?

    init(effect: Effect, card: NudgeCard, animateFor: Double, reduceMotion: Bool, scale: CGFloat = 1) {
        self.effect = effect
        self.card = card
        self.animateFor = animateFor
        self.reduceMotion = reduceMotion
        self.scale = scale
        face = effect == .funnyFace ? FunnyFace.load() : nil
    }

    nonisolated static let characterSize = CGSize(width: 150, height: 120)

    /// The character fills about 60% of a big panel's height, leaving room for the card under it.
    nonisolated static func scale(toFit panel: CGSize) -> CGFloat {
        min(panel.height * 0.6 / characterSize.height, panel.width / characterSize.width)
    }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || settled)) { context in
            // t == 0 renders the static frame used for Reduce Motion.
            let t = reduceMotion || settled ? 0 : context.date.timeIntervalSince(start)
            VStack(spacing: 8 * scale) {
                if effect != .shake {
                    Group {
                        switch effect {
                        case .cartoonShock: ShockGuy(t: t)
                        case .funnyFace: FunnyFace(t: t, image: face)
                        default: KnockDoor(t: t)
                        }
                    }
                    .scaleEffect(scale)
                    .frame(width: Self.characterSize.width * scale, height: Self.characterSize.height * scale)
                    .opacity(settled ? 0 : 1)
                    .animation(.easeOut(duration: 0.3), value: settled)
                }
                label.offset(x: effect == .shake ? Self.shakeOffset(t) : 0)
            }
            // The corner card sits at the panel's bottom; a big one is centered on the screen.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: scale > 1 ? .center : .bottom)
            .padding(.bottom, 8)
        }
        .task {
            try? await Task.sleep(for: .seconds(animateFor))
            settled = true
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            EffectIcon(effect: effect)
            NudgeCardText(card: card, title: title)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 4)
        .unreadBadge(card)
    }

    private var title: String {
        switch effect {
        case .knock: "\(card.sender) 在敲你的門"
        case .funnyFace: "\(card.sender) 對你做鬼臉"
        default: "\(card.sender) 戳了你一下"
        }
    }

    /// Seconds from the start; shared with the knock sound so picture and sound line up.
    nonisolated static let knockTimes: [Double] = [0, 0.22, 0.44]
    /// When each 「略」 pops in, after the character has bounced up; shared with the sound.
    nonisolated static let faceTimes: [Double] = [0.35, 0.6, 0.85]

    /// ~9 Hz side-to-side, decaying to rest after ~1.1 s.
    nonisolated static func shakeOffset(_ t: Double) -> CGFloat {
        let decay = max(0, 1 - t / 1.1)
        return CGFloat(sin(t * 2 * .pi * 9) * 16 * decay)
    }
}

/// Original cartoon character: round head, spiky hair, X eyes, local sparks.
private struct ShockGuy: View {
    let t: Double

    var body: some View {
        // Shown big in the middle of the screen, so the sparks pulse at 2 Hz between 45% and full
        // opacity: under the three-flashes-a-second limit for photosensitive viewers (WCAG 2.3.1).
        let sparksOn = t == 0 || Int(t * 4).isMultiple(of: 2)
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
                    .opacity(sparksOn ? 1 : 0.45)
            }
        }
        .frame(width: 130, height: 120)
        .offset(x: jitter)
    }
}

/// Door that jolts on each knock while "叩" marks pop in beside it.
private struct KnockDoor: View {
    let t: Double

    var body: some View {
        let times = NudgeView.knockTimes
        let sinceLast = times.map { t - $0 }.filter { $0 >= 0 }.min() ?? 1
        let jolt = t == 0 ? 0 : max(0, 1 - sinceLast / 0.15)

        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "door.left.hand.closed")
                .font(.system(size: 70))
                .foregroundStyle(Color(red: 0.55, green: 0.35, blue: 0.2))
                .rotationEffect(.degrees(jolt * 3), anchor: .bottomLeading)
                .offset(x: jolt * 2)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(times.indices, id: \.self) { i in
                    let since = t - times[i]
                    // Reduce Motion (t == 0) shows all three at rest.
                    let shown = t == 0 || since >= 0
                    let pop = t == 0 ? 1 : 1 + max(0, 0.4 - since * 3)
                    Text("叩")
                        .font(.system(size: 20, weight: .heavy))
                        .opacity(shown ? 1 : 0)
                        .scaleEffect(shown ? pop : 0.5)
                        .offset(x: CGFloat(i) * 8)
                }
            }
        }
        .frame(width: 150, height: 110)
    }
}

/// The author's animated character bounces up from below, wobbles, and taunts 「略略略」.
private struct FunnyFace: View {
    let t: Double
    let image: PetAnimation?

    /// The author's WebP, shipped as a lossless APNG with identical frames: ImageIO redecodes an
    /// animated WebP from its first frame for every frame (40 frames took ~2 s), an APNG ~0.1 s.
    /// Kept up to 720 px since it shows ~360 pt tall.
    nonisolated static func load() -> PetAnimation? {
        Bundle.main.url(forResource: "Face", withExtension: "apng").flatMap { PetAnimation(url: $0, maxPixelSize: 720) }
    }

    var body: some View {
        // Reduce Motion (t == 0) shows the character at rest with all three 「略」.
        let rise = t == 0 ? 1 : Self.easeOutBack(min(t / 0.35, 1))
        let wobble = t == 0 ? 0 : sin(t * 2 * .pi * 3) * 8 * max(0, 1 - t / 1.6)

        HStack(alignment: .center, spacing: 4) {
            Group {
                if let image {
                    Image(decorative: image.frame(at: t), scale: 1).resizable().scaledToFit()
                } else {
                    Text("😜").font(.system(size: 80))
                }
            }
            .frame(height: 112)
            .rotationEffect(.degrees(wobble), anchor: .bottom)
            .offset(y: (1 - rise) * 70)
            .opacity(min(1, rise * 3))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(NudgeView.faceTimes.indices, id: \.self) { i in
                    let since = t - NudgeView.faceTimes[i]
                    let shown = t == 0 || since >= 0
                    let pop = t == 0 ? 1 : 1 + max(0, 0.4 - since * 3)
                    Text("略")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(.pink)
                        .opacity(shown ? 1 : 0)
                        .scaleEffect(shown ? pop : 0.5)
                        .offset(x: CGFloat(i) * 6)
                }
            }
        }
        .frame(width: 150, height: 120)
    }

    /// Overshoots a little before settling, so the character pops up rather than slides.
    nonisolated static func easeOutBack(_ x: Double) -> Double {
        let c = 1.70158
        return 1 + (c + 1) * pow(x - 1, 3) + c * pow(x - 1, 2)
    }
}
