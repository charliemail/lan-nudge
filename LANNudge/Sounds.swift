import AVFoundation

/// Effect sounds synthesized at runtime: original, and no bundled audio assets to license.
/// Rhythms follow the animations (3 Hz sparks, 9 Hz shake, knock times).
@MainActor
enum Sounds {
    private static var player: AVAudioPlayer?

    static func play(_ effect: Effect) {
        player = try? AVAudioPlayer(data: wav(samples(for: effect)))
        player?.play()
    }

    nonisolated static let sampleRate = 44_100.0

    nonisolated static func samples(for effect: Effect) -> [Float] {
        switch effect {
        case .cartoonShock: zap(seconds: 1.6)
        case .shake: rattle(seconds: 1.1)
        case .knock: knock()
        case .funnyFace: taunt()
        }
    }

    /// Square-wave mains hum plus crackle, pulsing with the on-screen sparks.
    nonisolated private static func zap(seconds: Double) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        return (0..<Int(seconds * sampleRate)).map { i in
            let t = Double(i) / sampleRate
            let hum: Double = sin(2 * .pi * 110 * t) > 0 ? 1 : -1
            let crackle = Double.random(in: -1...1, using: &rng)
            let pulse = Int(t * 6).isMultiple(of: 2) ? 1.0 : 0.35
            let envelope = min(1, t / 0.01, (seconds - t) / 0.15)
            return Float((hum * 0.18 + crackle * 0.22) * pulse * envelope)
        }
    }

    /// Low thumps at the shake frequency, fading with the shake.
    nonisolated private static func rattle(seconds: Double) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { i in
            let t = Double(i) / sampleRate
            let sinceThump = (t * 9).truncatingRemainder(dividingBy: 1) / 9
            let thump = sin(2 * .pi * 90 * sinceThump) * exp(-sinceThump / 0.02)
            return Float(thump * 0.6 * max(0, 1 - t / seconds))
        }
    }

    /// Knuckle on wood: a short decaying low tone with a click on the attack.
    nonisolated private static func knock() -> [Float] {
        var rng = SystemRandomNumberGenerator()
        var out = [Float](repeating: 0, count: Int(0.8 * sampleRate))
        for start in NudgeView.knockTimes {
            let offset = Int(start * sampleRate)
            for j in 0..<Int(0.12 * sampleRate) where offset + j < out.count {
                let t = Double(j) / sampleRate
                let wood = (sin(2 * .pi * 170 * t) + 0.5 * sin(2 * .pi * 310 * t)) * exp(-t / 0.018)
                let click = Double.random(in: -1...1, using: &rng) * exp(-t / 0.002)
                out[offset + j] += Float(wood * 0.4 + click * 0.3)
            }
        }
        return out
    }

    /// A rising "boing" as the character pops up, then three nasal 「略」 blips that fall in pitch.
    nonisolated private static func taunt() -> [Float] {
        var out = [Float](repeating: 0, count: Int(1.1 * sampleRate))
        var phase = 0.0
        for j in 0..<Int(0.3 * sampleRate) {
            let t = Double(j) / sampleRate
            phase += 2 * .pi * (180 + 900 * t) / sampleRate
            out[j] += Float(sin(phase) * 0.45 * min(1, t / 0.01) * exp(-t / 0.12))
        }
        for start in NudgeView.faceTimes {
            let offset = Int(start * sampleRate)
            var phase = 0.0
            for j in 0..<Int(0.16 * sampleRate) where offset + j < out.count {
                let t = Double(j) / sampleRate
                phase += 2 * .pi * (620 - 1000 * t + 25 * sin(2 * .pi * 30 * t)) / sampleRate
                // Square-ish wave through a soft clip: a buzzy, nasal "leh".
                let tone = tanh(3 * sin(phase)) * 0.3
                out[offset + j] += Float(tone * min(1, t / 0.008) * exp(-t / 0.07))
            }
        }
        return out
    }

    /// 16-bit mono PCM WAV.
    nonisolated static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let rate = UInt32(sampleRate)
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: "RIFF".utf8); put(36 + byteCount); data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(rate); put(rate * 2); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: "data".utf8); put(byteCount)
        for sample in samples { put(Int16(max(-1, min(1, sample)) * Float(Int16.max))) }
        return data
    }
}
