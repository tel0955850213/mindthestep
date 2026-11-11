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
    /// Two or more steps the same way in a row.
    var isStairs = false
    /// World height of the ground reference and of the step's upper surface (for AR markers).
    var groundRefM: Float = 0
    var edgeHeightM: Float = 0

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
    /// A bin whose 10th–90th percentile heights differ more than this is a vertical face, not ground.
    var maxBinSpread: Float = 0.07
    /// Each side of a step must be a flat surface over this many bins (15 cm)...
    var flatBins = 4
    /// Real steps and curbs; anything taller is treated as an obstacle (chair seat, bag, person).
    var maxStepUp: Float = 0.25
    var maxStepDown: Float = 0.35
    var minCameraHeight: Float = 0.7
    var maxCameraHeight: Float = 2.1
    /// ...varying by no more than this.
    var maxFlatRange: Float = 0.05
}

/// Pure geometry: turns one frame of ground samples into a hazard decision.
struct StepDetector {
    var config = DetectorConfig()

    func forward(ofBin i: Int) -> Float {
        config.minForward + (Float(i) + 0.5) * config.binSize
    }

    /// - Parameter cameraY: world height of the phone, used to reject tables/seats as "ground".
    func analyze(_ samples: [GroundSample], cameraY: Float? = nil) -> DetectionResult {
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
        // A walking phone sits roughly 0.7–2 m above the floor. If the "ground" is much closer,
        // we're looking at a table or seat, not the walking surface.
        if let cameraY, cameraY - ref < c.minCameraHeight || cameraY - ref > c.maxCameraHeight {
            return base(.unknown, "Hold the phone at chest height",
                        profile: Array(repeating: nil, count: binCount))
        }

        // 2. Keep only walkable surface: drop walls/objects far above the reference, and drop
        //    "mixed" bins whose heights spread widely (vertical faces such as risers or the
        //    wall at the bottom of a staircase). Those used to masquerade as false step-ups.
        let medians: [Float?] = bins.map { hs in
            let kept = hs.filter { $0 - ref <= c.maxAboveGround && ref - $0 <= c.maxBelowGround }.sorted()
            guard kept.count >= c.minPointsPerBin else { return nil }
            let p10 = kept[kept.count / 10], p90 = kept[(kept.count * 9) / 10]
            guard p90 - p10 <= c.maxBinSpread else { return nil }
            return median(kept)
        }
        let profile = medians.map { $0.map { ($0 - ref) * 100 } }
        let valid: [(i: Int, h: Float)] = medians.indices.compactMap { i in medians[i].map { (i, $0) } }
        guard valid.count >= 2 * c.minValidInWindow else {
            return base(.unknown, "Not enough ground points", profile: profile)
        }

        // 3. Nearest abrupt height change between two flat surfaces.
        if let s = findStep(in: valid, from: 1) {
            // Taller than any real step or curb: a chair seat, bag or person, or a deep drop
            // we can't measure reliably. Warn softly as UNKNOWN instead of guessing.
            if s.height > c.maxStepUp || -s.height > c.maxStepDown {
                var r = base(.unknown, s.height > 0 ? "Obstacle ahead" : "Large drop or obstacle ahead",
                             profile: profile)
                r.distanceM = forward(ofBin: valid[s.edge].i)
                return r
            }
            var r = base(s.height > 0 ? .stepUp : .stepDown,
                         s.occluded ? "Edge partly hidden" : "", profile: profile)
            r.heightCm = s.height * 100
            r.distanceM = forward(ofBin: valid[s.edge].i)
            r.confidence = s.support * (s.occluded ? 0.8 : 1)
            r.groundRefM = ref
            r.edgeHeightM = s.upperHeight
            // Another riser-sized step the same way, of similar height, within ~70 cm means stairs.
            let riser: ClosedRange<Float> = 0.10...0.22
            if let next = findStep(in: valid, from: s.edge + 1),
               (next.height > 0) == (s.height > 0),
               riser.contains(abs(s.height)), riser.contains(abs(next.height)),
               abs(abs(next.height) - abs(s.height)) <= 0.06,
               forward(ofBin: valid[next.edge].i) - r.distanceM <= 0.7 {
                r.isStairs = true
            }
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
        r.groundRefM = ref
        return r
    }

    struct Step {
        var edge: Int          // index into `valid` of the first bin past the edge
        var height: Float      // metres, signed
        var occluded: Bool
        var support: Float
        var upperHeight: Float // world height of the higher surface (for the AR marker)
    }

    /// Finds the nearest abrupt height change at or after `start` where both sides are flat.
    func findStep(in valid: [(i: Int, h: Float)], from start: Int) -> Step? {
        let c = config
        guard start < valid.count else { return nil }
        for j in max(1, start)..<valid.count {
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
                if jump > maxJump { maxJump = jump; edge = k; occluded = valid[k].i - valid[k - 1].i > 1 }
            }
            guard maxJump >= c.abruptFraction * abs(d) else { continue }  // gradual: ramp, not a step

            // Re-measure with windows anchored on the edge; both sides must be flat surfaces.
            let near = Array(valid[max(0, edge - c.windowBins)..<edge])
            let far = Array(valid[edge..<min(valid.count, edge + c.flatBins)])
            guard near.count >= c.minValidInWindow, far.count >= c.minValidInWindow else { continue }
            let nearTail = near.suffix(c.flatBins).map { $0.h }
            let farHead = far.map { $0.h }
            guard (nearTail.max()! - nearTail.min()!) <= c.maxFlatRange,
                  (farHead.max()! - farHead.min()!) <= c.maxFlatRange else { continue }
            let nearH = median(nearTail), farH = median(farHead)
            let height = farH - nearH
            guard abs(height) >= c.stepThreshold else { continue }

            let support = min(1, Float(near.count + far.count) / Float(c.windowBins + c.flatBins))
            return Step(edge: edge, height: height, occluded: occluded, support: support,
                        upperHeight: max(nearH, farH))
        }
        return nil
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
