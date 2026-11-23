import AVFoundation
import Testing
@testable import LANNudge

struct SoundsTests {
    @Test(arguments: Effect.allCases)
    func audibleUnclippedAndPlayable(_ effect: Effect) throws {
        let samples = Sounds.samples(for: effect)
        let peak = samples.map(abs).max() ?? 0
        #expect(peak > 0.1)
        #expect(peak <= 1)

        let player = try AVAudioPlayer(data: Sounds.wav(samples))
        #expect(abs(player.duration - Double(samples.count) / Sounds.sampleRate) < 0.01)
        #expect(player.duration < 2)
    }
}
