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
            let up = r.kind == .stepUp
            if Lang.isChinese {
                speak(r.isStairs ? (up ? "樓梯往上。" : "樓梯往下。") : (up ? "往上一階，\(cm) 公分。" : "往下一階，\(cm) 公分。"))
            } else {
                speak(r.isStairs ? "Stairs \(up ? "up" : "down")." : "Step \(up ? "up" : "down"), \(cm).")
            }
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
        u.voice = AVSpeechSynthesisVoice(language: Lang.isChinese ? "zh-TW" : "en-US")
        u.rate = Lang.isChinese ? 0.5 : 0.55
        synth.speak(u)
    }
}
