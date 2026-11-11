import AVFoundation
import UIKit

/// Haptics fire immediately; speech is short and never blocks the next haptic. Use on the main thread.
final class AlertPlayer {
    private let synth = AVSpeechSynthesizer()
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let light = UIImpactFeedbackGenerator(style: .light)
    var speechEnabled = true

    init() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? s.setActive(true)
        heavy.prepare()
        light.prepare()
    }

    func alert(_ r: DetectionResult) {
        switch r.kind {
        case .stepUp, .stepDown:
            let major = abs(r.heightCm) > 15
            pulse(heavy, times: major ? 3 : 2)
            let cm = Int(abs(r.heightCm).rounded())
            let dir = r.kind == .stepUp ? "up" : "down"
            speak(r.isStairs ? "Stairs \(dir)." : "Step \(dir), \(cm).")
        case .unknown:
            light.impactOccurred()
        case .clear, .ramp:
            break
        }
        heavy.prepare()
        light.prepare()
    }

    private func pulse(_ g: UIImpactFeedbackGenerator, times: Int) {
        for i in 0..<times {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14 * Double(i)) {
                g.impactOccurred(intensity: 1.0)
            }
        }
    }

    private func speak(_ text: String) {
        guard speechEnabled else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        u.rate = 0.55
        synth.speak(u)
    }
}
