import Foundation

/// One LiDAR point projected onto the walking corridor.
struct GroundSample: Equatable {
    /// Horizontal distance ahead of the phone, in metres.
    var forward: Float
    /// Gravity-aligned world height, in metres.
    var height: Float
}

enum HazardKind: String, Equatable {
    case clear, stepUp, stepDown, ramp, unknown
}

struct DetectionResult: Equatable {
    var kind: HazardKind
    /// Signed height change in cm (+ up, - down). Steps only.
    var heightCm: Float = 0
    /// Distance ahead of the phone, in metres.
    var distanceM: Float = 0
    var slopePercent: Float = 0
    /// 0...1, how much depth support the decision had.
    var confidence: Float = 0
    var reason: String = ""
    /// Per-bin median height relative to the ground reference, in cm (nil = no data).
    var profileCm: [Float?] = []
    var binSize: Float = 0.05
    var minForward: Float = 0.3

    static let empty = DetectionResult(kind: .unknown, reason: "Waiting for depth")
}

struct DetectorConfig {
    var minForward: Float = 0.3
    var maxForward: Float = 2.5
    var binSize: Float = 0.05
    var minPointsPerBin = 6
    /// 4 bins = 20 cm comparison windows.
    var windowBins = 4
    var minValidInWindow = 3
    /// Start conservative (8 cm); lower only after measured validation.
    var stepThreshold: Float = 0.08
    /// Points this far above the ground reference are walls/objects, not walking surface.
    var maxAboveGround: Float = 0.40
    var maxBelowGround: Float = 0.80
    /// The nearest 30 cm of visible ground defines the reference height.
    var referenceBins = 6
    var maxReferenceStart: Float = 1.2
    /// A real step concentrates most of its height change in one bin (or across an occluded gap).
    var abruptFraction: Float = 0.5
    /// If visible ground ends this close, what lies beyond is UNKNOWN (often a hidden drop-off).
    var unknownWithin: Float = 1.8
    var rampSlope: Float = 0.06
}

/// Pure geometry: turns one frame of ground samples into a hazard decision.
struct StepDetector {
    var config = DetectorConfig()

    func forward(ofBin i: Int) -> Float {
        config.minForward + (Float(i) + 0.5) * config.binSize
    }

    func analyze(_ samples: [GroundSample]) -> DetectionResult {
        let c = config
        let binCount = Int(((c.maxForward - c.minForward) / c.binSize).rounded())
        var bins = Array(repeating: [Float](), count: binCount)
        for s in samples where s.forward >= c.minForward && s.forward < c.maxForward {
            let i = Int((s.forward - c.minForward) / c.binSize)
            if i >= 0 && i < binCount { bins[i].append(s.height) }
        }

        func base(_ kind: HazardKind, _ reason: String, profile: [Float?]) -> DetectionResult {
            DetectionResult(kind: kind, reason: reason, profileCm: profile,
                            binSize: c.binSize, minForward: c.minForward)
        }

        // 1. Ground reference from the nearest visible ground.
        let provisional: [Float?] = bins.map { $0.count >= c.minPointsPerBin ? median($0) : nil }
        let provisionalValid = provisional.indices.filter { provisional[$0] != nil }
        guard let first = provisionalValid.first,
              forward(ofBin: first) <= c.maxReferenceStart,
              provisionalValid.count >= c.referenceBins else {
            return base(.unknown, "Can't see the ground ahead",
                        profile: Array(repeating: nil, count: binCount))
        }
        let ref = median(provisionalValid.prefix(c.referenceBins).map { provisional[$0]! })

        // 2. Drop points that clearly aren't walking surface (walls, boxes, people).
        let medians: [Float?] = bins.map { hs in
            let kept = hs.filter { $0 - ref <= c.maxAboveGround && ref - $0 <= c.maxBelowGround }
            return kept.count >= c.minPointsPerBin ? median(kept) : nil
        }
        let profile = medians.map { $0.map { ($0 - ref) * 100 } }
        let valid: [(i: Int, h: Float)] = medians.indices.compactMap { i in medians[i].map { (i, $0) } }
        guard valid.count >= 2 * c.minValidInWindow else {
            return base(.unknown, "Not enough ground points", profile: profile)
        }

        // 3. Nearest abrupt height change with support on both sides.
        for j in 1..<valid.count {
            let before = valid[max(0, j - c.windowBins)..<j]
            let after = valid[j..<min(valid.count, j + c.windowBins)]
            guard before.count >= c.minValidInWindow, after.count >= c.minValidInWindow else { continue }
            let d = median(after.map { $0.h }) - median(before.map { $0.h })
            guard abs(d) >= c.stepThreshold else { continue }

            // Locate the sharpest single jump around here.
            var edge = j
            var maxJump: Float = 0
            var occluded = false
            let upper = min(valid.count - 1, j + c.windowBins - 1)
            for k in max(1, j - 1)...upper {
                let jump = abs(valid[k].h - valid[k - 1].h)
                let gap = valid[k].i - valid[k - 1].i > 1
                if jump > maxJump { maxJump = jump; edge = k; occluded = gap }
            }
            guard maxJump >= c.abruptFraction * abs(d) else { continue }  // gradual: ramp, not a step

            // Re-measure the height with windows anchored on the edge itself.
            let near = valid[max(0, edge - c.windowBins)..<edge]
            let far = valid[edge..<min(valid.count, edge + c.windowBins)]
            guard near.count >= c.minValidInWindow, far.count >= c.minValidInWindow else { continue }
            let height = median(far.map { $0.h }) - median(near.map { $0.h })
            guard abs(height) >= c.stepThreshold else { continue }

            let support = Float(near.count + far.count) / Float(2 * c.windowBins)
            var r = base(height > 0 ? .stepUp : .stepDown,
                         occluded ? "Edge partly hidden" : "", profile: profile)
            r.heightCm = height * 100
            r.distanceM = forward(ofBin: valid[edge].i)
            r.confidence = min(1, support) * (occluded ? 0.8 : 1)
            return r
        }

        // 4. Visible ground ends early: whatever is beyond is unknown, never safe.
        let lastForward = forward(ofBin: valid.last!.i)
        if lastForward + c.binSize < c.unknownWithin {
            var r = base(.unknown, String(format: "Ground not visible past %.1f m", lastForward),
                         profile: profile)
            r.distanceM = lastForward
            return r
        }

        // 5. Gentle slope is reported, not alerted.
        let slope = linearSlope(valid.map { (forward(ofBin: $0.i), $0.h) })
        var r = base(abs(slope) >= c.rampSlope ? .ramp : .clear, "", profile: profile)
        r.slopePercent = slope * 100
        r.confidence = min(1, Float(valid.count) / Float(binCount))
        return r
    }
}

/// Requires a hazard to persist across frames before alerting, then cools down.
struct StepTracker {
    var window = 5
    var required = 3
    var requiredUnknown = 4
    var cooldown: TimeInterval = 3
    var unknownCooldown: TimeInterval = 4
    var maxHeightSpreadCm: Float = 6
    private(set) var history: [DetectionResult] = []
    private var lastAlert: [HazardKind: TimeInterval] = [:]

    mutating func update(_ r: DetectionResult, now: TimeInterval) -> DetectionResult? {
        history.append(r)
        if history.count > window { history.removeFirst(history.count - window) }
        guard r.kind == .stepUp || r.kind == .stepDown || r.kind == .unknown else { return nil }

        let same = history.filter { $0.kind == r.kind }
        guard same.count >= (r.kind == .unknown ? requiredUnknown : required) else { return nil }
        if r.kind != .unknown {
            let hs = same.map { $0.heightCm }
            guard let lo = hs.min(), let hi = hs.max(), hi - lo <= maxHeightSpreadCm else { return nil }
        }
        let wait = r.kind == .unknown ? unknownCooldown : cooldown
        if let t = lastAlert[r.kind], now - t < wait { return nil }
        lastAlert[r.kind] = now

        var confirmed = r
        confirmed.heightCm = median(same.map { $0.heightCm })
        confirmed.distanceM = median(same.map { $0.distanceM })
        return confirmed
    }
}

func median(_ xs: [Float]) -> Float {
    precondition(!xs.isEmpty)
    let s = xs.sorted()
    let m = s.count / 2
    return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
}

func linearSlope(_ pts: [(Float, Float)]) -> Float {
    guard pts.count >= 2 else { return 0 }
    let n = Float(pts.count)
    let mx = pts.reduce(0) { $0 + $1.0 } / n
    let my = pts.reduce(0) { $0 + $1.1 } / n
    var num: Float = 0, den: Float = 0
    for (x, y) in pts { num += (x - mx) * (y - my); den += (x - mx) * (x - mx) }
    return den > 0 ? num / den : 0
}
