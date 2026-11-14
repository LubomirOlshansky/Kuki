import AVFoundation
import UIKit

/// A fūrin (風鈴) — the glass wind bell hung in Japanese windows in summer.
/// Synthesised, not sampled: two soft strikes of a bell-like tone that rings
/// out. It says "open the window" without sounding like an alarm.
@MainActor
final class Chime {
    static let shared = Chime()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private lazy var buffer: AVAudioPCMBuffer? = Self.render()

    private init() {
        engine.attach(player)
    }

    func ring() {
        do {
            let session = AVAudioSession.sharedInstance()
            // Ambient: mixes with whatever is playing and respects the silent switch.
            try session.setCategory(.ambient, options: [.mixWithOthers])
            try session.setActive(true)
            guard let buffer else { return }
            if !engine.isRunning {
                engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
                try engine.start()
            }
            player.scheduleBuffer(buffer, at: nil, options: [.interrupts])
            player.play()
        } catch {
            // A missing chime must never break recording.
        }
        haptic()
    }

    private func haptic() {
        #if !targetEnvironment(macCatalyst)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)
        #endif
    }

    private static func render() -> AVAudioPCMBuffer? {
        let sampleRate = 44_100.0
        let seconds = 4.0
        let frames = AVAudioFrameCount(sampleRate * seconds)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames

        // Inharmonic partials of a small bell; higher ones die faster.
        let base = 1_396.9 // F6
        let partials: [(ratio: Double, amp: Double, decay: Double)] = [
            (1.000, 1.00, 1.50),
            (1.004, 0.55, 1.40), // a near-twin gives the slow shimmer
            (2.756, 0.38, 0.75),
            (5.404, 0.16, 0.35),
            (8.933, 0.07, 0.18),
        ]
        let strikes: [(time: Double, gain: Double, pitch: Double)] = [
            (0.00, 1.00, 1.0),
            (0.46, 0.62, 1.0 * pow(2, -2.0 / 12)), // a second, softer, slightly lower strike
        ]

        var peak: Float = 0
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            var sample = 0.0
            for strike in strikes where t >= strike.time {
                let local = t - strike.time
                let attack = min(1, local / 0.004)
                for p in partials {
                    sample += strike.gain * p.amp * attack * exp(-local / p.decay)
                        * sin(2 * .pi * base * strike.pitch * p.ratio * local)
                }
            }
            let fadeOut = t > seconds - 0.3 ? (seconds - t) / 0.3 : 1
            let value = Float(sample * fadeOut)
            data[i] = value
            peak = max(peak, abs(value))
        }
        // Quiet on purpose: about −12 dBFS peak.
        if peak > 0 {
            let gain = 0.25 / peak
            for i in 0..<Int(frames) { data[i] *= gain }
        }
        return buffer
    }
}
