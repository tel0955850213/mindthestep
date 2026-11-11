import ARKit
import CoreImage
import QuartzCore
import RealityKit
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
    @Published var showDiagnostics = false
    @Published var showHazards = false
    let store = HazardStore()
    let family = FamilyNotifier()
    @Published var familyNotice: FamilyNotice?
    private let location = LocationProvider()
    private let ciContext = CIContext()
    @Published var thresholdCm: Double = 8 {
        didSet {
            let v = Float(thresholdCm / 100)
            queue.async { self.detector.config.stepThreshold = v }
        }
    }
    @Published var speechOn = true { didSet { alerts.speechEnabled = speechOn } }

    let supported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    let session = ARSession()
    /// A glowing line drawn on the real step edge.
    let markerAnchor = AnchorEntity(world: .zero)

    private let queue = DispatchQueue(label: "mindthestep.depth", qos: .userInteractive)
    private var detector = StepDetector()
    private var tracker = StepTracker()
    private let alerts = AlertPlayer()
    private var lastFingerprint: Float = -1
    private var uniqueFrames = 0
    private var fpsWindowStart = CACurrentMediaTime()
    private var lastPublish: CFTimeInterval = 0
    private var lastStepSeen: CFTimeInterval = 0
    private let markerLine: ModelEntity
    private let markerGlow: ModelEntity

    override init() {
        markerLine = ModelEntity(mesh: .generateBox(width: 0.5, height: 0.006, depth: 0.025),
                                 materials: [UnlitMaterial(color: .systemRed)])
        markerGlow = ModelEntity(mesh: .generateBox(width: 0.5, height: 0.003, depth: 0.06),
                                 materials: [UnlitMaterial(color: UIColor.systemRed.withAlphaComponent(0.2))])
        markerGlow.position.z = 0.03  // thin halo just on the user's side of the edge
        super.init()
        markerAnchor.addChild(markerLine)
        markerAnchor.addChild(markerGlow)
        markerAnchor.isEnabled = false
    }

    func start() {
        guard supported else { return }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth]
        session.delegateQueue = queue
        session.delegate = self
        session.run(config)
        location.start()
    }

    /// Portrait JPEG thumbnail of the camera frame, for the hazard log.
    private func snapshot(_ pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let scale = 480 / image.extent.width
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return ciContext.jpegRepresentation(of: scaled, colorSpace: CGColorSpaceCreateDeviceRGB(),
                                            options: [key: 0.7])
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let t0 = CACurrentMediaTime()
        let trackingText = Self.describe(frame.camera.trackingState)
        let frameTime = frame.timestamp

        var r: DetectionResult
        var count = 0
        var marker: (position: SIMD3<Float>, yaw: Float)?
        if let out = DepthProcessor.groundSamples(frame: frame) {
            if out.fingerprint != lastFingerprint {
                uniqueFrames += 1
                lastFingerprint = out.fingerprint
            }
            count = out.samples.count
            r = out.headingOK
                ? detector.analyze(out.samples, cameraY: out.cameraY)
                : DetectionResult(kind: .unknown, reason: "Tilt the phone forward")
            if r.kind == .stepUp || r.kind == .stepDown {
                let xz = out.cameraXZ + out.heading * r.distanceM
                marker = (SIMD3<Float>(xz.x, r.edgeHeightM + 0.01, xz.y),
                          atan2(-out.heading.x, -out.heading.y))
            }
        } else {
            r = DetectionResult(kind: .unknown, reason: "No depth this frame")
        }
        let confirmed = tracker.update(r, now: t0)
        let isStep = confirmed.map { $0.kind == .stepUp || $0.kind == .stepDown } ?? false
        let photo = isStep ? snapshot(frame.capturedImage) : nil

        let t1 = CACurrentMediaTime()
        let procMs = (t1 - t0) * 1000
        let latencyMs = (t1 - frameTime) * 1000
        var fps: Double?
        if t1 - fpsWindowStart >= 1 {
            fps = Double(uniqueFrames) / (t1 - fpsWindowStart)
            uniqueFrames = 0
            fpsWindowStart = t1
        }
        if marker != nil { lastStepSeen = t1 }
        let hideMarker = marker == nil && t1 - lastStepSeen > 0.6
        guard confirmed != nil || marker != nil || t1 - lastPublish > 0.05 else { return }
        lastPublish = t1

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.result = r
            self.processingMs = procMs
            self.tracking = trackingText
            self.points = count
            if let fps { self.depthFPS = fps }
            if let m = marker { self.placeMarker(m.position, yaw: m.yaw, major: abs(r.heightCm) > 15) }
            if hideMarker { self.markerAnchor.isEnabled = false }
            if let c = confirmed {
                self.alerts.alert(c)
                self.lastAlert = c
                self.lastAlertTime = Date()
                self.alertLatencyMs = latencyMs
                if isStep { self.store.record(c, location: self.location.last, photo: photo) }
                if self.family.shouldNotify(c) { self.notifyFamily(c) }
            }
        }
    }

    /// Push a real alert to family, showing the banner while it sends and once it lands. Main thread.
    private func notifyFamily(_ r: DetectionResult) {
        let text = family.message(for: r)
        let notice = FamilyNotice(state: .sending, message: text)
        familyNotice = notice
        Task {
            let ok = await family.send(text)
            await MainActor.run {
                guard self.familyNotice?.id == notice.id else { return }
                self.familyNotice = FamilyNotice(id: notice.id, state: ok ? .delivered : .failed, message: text)
            }
            try? await Task.sleep(for: .seconds(3.5))
            await MainActor.run {
                if self.familyNotice?.id == notice.id { self.familyNotice = nil }
            }
        }
    }

    private func placeMarker(_ p: SIMD3<Float>, yaw: Float, major: Bool) {
        let color: UIColor = major ? .systemRed : .systemOrange
        markerLine.model?.materials = [UnlitMaterial(color: color)]
        markerGlow.model?.materials = [UnlitMaterial(color: color.withAlphaComponent(0.2))]
        markerAnchor.position = p
        markerAnchor.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        markerAnchor.isEnabled = true
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
