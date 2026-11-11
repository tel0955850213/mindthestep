import XCTest
@testable import MindTheStep

final class StepDetectorTests: XCTestCase {
    /// Deterministic ±1.5 cm noise, roughly what we saw in real iPhone scans.
    private func noise(_ i: Int) -> Float {
        Float((i * 7919) % 31 - 15) / 1000
    }

    /// 20 points every 2.5 cm from 0.3 to 2.5 m, height given by `profile`.
    private func samples(_ profile: (Float) -> Float?) -> [GroundSample] {
        var out: [GroundSample] = []
        var i = 0
        var f: Float = 0.3
        while f < 2.5 {
            if let h = profile(f) {
                for _ in 0..<20 {
                    out.append(GroundSample(forward: f, height: h + noise(i)))
                    i += 1
                }
            }
            f += 0.025
        }
        return out
    }

    func testFlatGroundIsClear() {
        let r = StepDetector().analyze(samples { _ in 0 })
        XCTAssertEqual(r.kind, .clear)
    }

    func testDetectsDropOff() {
        let r = StepDetector().analyze(samples { $0 < 1.2 ? 0 : -0.15 })
        XCTAssertEqual(r.kind, .stepDown)
        XCTAssertEqual(r.heightCm, -15, accuracy: 2.5)
        XCTAssertEqual(r.distanceM, 1.2, accuracy: 0.1)
    }

    func testDetectsStepUp() {
        let r = StepDetector().analyze(samples { $0 < 1.0 ? 0 : 0.17 })
        XCTAssertEqual(r.kind, .stepUp)
        XCTAssertEqual(r.heightCm, 17, accuracy: 2.5)
        XCTAssertEqual(r.distanceM, 1.0, accuracy: 0.1)
    }

    func testDropWithOccludedLowerEdge() {
        // The lower ground just past a curb is hidden from a chest-height phone.
        let r = StepDetector().analyze(samples { f in
            f < 1.0 ? 0 : (f < 1.25 ? nil : -0.15)
        })
        XCTAssertEqual(r.kind, .stepDown)
        XCTAssertEqual(r.heightCm, -15, accuracy: 2.5)
    }

    func testGentleRampIsNotAStep() {
        let r = StepDetector().analyze(samples { $0 * 0.10 })
        XCTAssertEqual(r.kind, .ramp)
        XCTAssertEqual(r.slopePercent, 10, accuracy: 2)
    }

    func testSmallBumpBelowThresholdIsIgnored() {
        let r = StepDetector().analyze(samples { $0 < 1.2 ? 0 : 0.04 })
        XCTAssertEqual(r.kind, .clear)
    }

    func testGroundEndingEarlyIsUnknown() {
        let r = StepDetector().analyze(samples { $0 < 1.0 ? 0 : nil })
        XCTAssertEqual(r.kind, .unknown)
    }

    func testNoGroundIsUnknown() {
        XCTAssertEqual(StepDetector().analyze([]).kind, .unknown)
    }

    func testWallIsNotTreatedAsStep() {
        // Points far above the ground (a wall at 1.5 m) are excluded, so ground "ends": unknown, not a step up.
        let r = StepDetector().analyze(samples { $0 < 1.5 ? 0 : 1.2 })
        XCTAssertEqual(r.kind, .unknown)
    }

    func testTrackerNeedsPersistenceAndCoolsDown() {
        var t = StepTracker()
        let step = DetectionResult(kind: .stepDown, heightCm: -15, distanceM: 1.2)
        XCTAssertNil(t.update(step, now: 0))
        XCTAssertNil(t.update(step, now: 0.02))
        XCTAssertNotNil(t.update(step, now: 0.04))
        XCTAssertNil(t.update(step, now: 0.06), "cooldown")
        XCTAssertNotNil(t.update(step, now: 3.5))
    }
}
