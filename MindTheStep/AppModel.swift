import ARKit
import QuartzCore
import SwiftUI

/// Owns the AR session. Depth processing runs on a private queue; UI updates hop to main.
final class AppModel: NSObject, ObservableObject, ARSessionDelegate {
    @Published var result = DetectionResult.empty
    @Published var lastAlert: DetectionResult?
    @Published var lastAlertTime: Date?
    @Published var depthFPS: Double = 0
    @Published var processingMs: Double = 0
    @Published var alertLatencyMs: Double = 0
    @Published var tracking = "—"
    @Published var points = 0
    @Published var thresholdCm: Double = 8 {
        didSet {
            let v = Float(thresholdCm / 100)
            queue.async { self.detector.config.stepThreshold = v }
        }
    }
    @Published var speechOn = true { didSet { alerts.speechEnabled = speechOn } }

    let supported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    let session = ARSession()

    private let queue = DispatchQueue(label: "mindthestep.depth", qos: .userInteractive)
    private var detector = StepDetector()
    private var tracker = StepTracker()
    private let alerts = AlertPlayer()
    private var lastFingerprint: Float = -1
    private var uniqueFrames = 0
    private var fpsWindowStart = CACurrentMediaTime()
    private var lastPublish: CFTimeInterval = 0

    func start() {
        guard supported else { return }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth]
        session.delegateQueue = queue
        session.delegate = self
        session.run(config)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let t0 = CACurrentMediaTime()
        let trackingText = Self.describe(frame.camera.trackingState)
        let frameTime = frame.timestamp

        var r: DetectionResult
        var count = 0
        if let out = DepthProcessor.groundSamples(frame: frame) {
            if out.fingerprint != lastFingerprint {
                uniqueFrames += 1
                lastFingerprint = out.fingerprint
            }
            count = out.samples.count
            r = out.headingOK
                ? detector.analyze(out.samples)
                : DetectionResult(kind: .unknown, reason: "Tilt the phone forward")
        } else {
            r = DetectionResult(kind: .unknown, reason: "No depth this frame")
        }
        let confirmed = tracker.update(r, now: t0)

        let t1 = CACurrentMediaTime()
        let procMs = (t1 - t0) * 1000
        let latencyMs = (t1 - frameTime) * 1000
        var fps: Double?
        if t1 - fpsWindowStart >= 1 {
            fps = Double(uniqueFrames) / (t1 - fpsWindowStart)
            uniqueFrames = 0
            fpsWindowStart = t1
        }
        guard confirmed != nil || t1 - lastPublish > 0.05 else { return }
        lastPublish = t1

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.result = r
            self.processingMs = procMs
            self.tracking = trackingText
            self.points = count
            if let fps { self.depthFPS = fps }
            if let c = confirmed {
                self.alerts.alert(c)
                self.lastAlert = c
                self.lastAlertTime = Date()
                self.alertLatencyMs = latencyMs
            }
        }
    }

    private static func describe(_ s: ARCamera.TrackingState) -> String {
        switch s {
        case .normal: return "normal"
        case .notAvailable: return "unavailable"
        case .limited(let reason):
            switch reason {
            case .initializing: return "initializing"
            case .excessiveMotion: return "too much motion"
            case .insufficientFeatures: return "low features"
            case .relocalizing: return "relocalizing"
            @unknown default: return "limited"
            }
        }
    }
}
