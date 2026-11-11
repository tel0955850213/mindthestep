import ARKit
import simd

struct DepthFrameOutput {
    var samples: [GroundSample]
    /// False when the phone points almost straight down, so "forward" is undefined.
    var headingOK: Bool
    /// Cheap fingerprint used to count genuinely new depth frames.
    var fingerprint: Float
}

/// Converts ARKit LiDAR depth into gravity-aligned ground samples along the walking corridor.
enum DepthProcessor {
    static func groundSamples(frame: ARFrame,
                              stride step: Int = 3,
                              corridorHalfWidth: Float = 0.3,
                              maxForward: Float = 2.6) -> DepthFrameOutput? {
        // Single-frame depth on purpose: smoothedSceneDepth averages across frames and adds lag.
        guard let depth = frame.sceneDepth, let conf = depth.confidenceMap else { return nil }
        let depthMap = depth.depthMap

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(conf, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(conf, .readOnly)
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }
        guard let dBase = CVPixelBufferGetBaseAddress(depthMap),
              let cBase = CVPixelBufferGetBaseAddress(conf) else { return nil }
        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)
        let dRowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        let cRowBytes = CVPixelBufferGetBytesPerRow(conf)

        // Intrinsics are for the full camera image; scale them to the depth map.
        let res = frame.camera.imageResolution
        let sx = Float(w) / Float(res.width)
        let sy = Float(h) / Float(res.height)
        let K = frame.camera.intrinsics
        let fx = K[0][0] * sx, fy = K[1][1] * sy
        let cx = K[2][0] * sx, cy = K[2][1] * sy

        let T = frame.camera.transform
        let cam = SIMD3<Float>(T.columns.3.x, T.columns.3.y, T.columns.3.z)
        let look = -SIMD3<Float>(T.columns.2.x, T.columns.2.y, T.columns.2.z)
        var heading = SIMD2<Float>(look.x, look.z)
        let hl = simd_length(heading)
        guard hl > 0.25 else { return DepthFrameOutput(samples: [], headingOK: false, fingerprint: 0) }
        heading /= hl

        var out: [GroundSample] = []
        out.reserveCapacity((w / step) * (h / step))
        var fingerprint: Float = 0
        let highConfidence = UInt8(ARConfidenceLevel.high.rawValue)

        for v in Swift.stride(from: 0, to: h, by: step) {
            let dRow = dBase.advanced(by: v * dRowBytes).assumingMemoryBound(to: Float32.self)
            let cRow = cBase.advanced(by: v * cRowBytes).assumingMemoryBound(to: UInt8.self)
            fingerprint += dRow[w / 2]
            for u in Swift.stride(from: 0, to: w, by: step) {
                let d = dRow[u]
                guard d > 0.1, d < 5, cRow[u] >= highConfidence else { continue }
                // Camera space: +x right, +y up, -z forward (image v grows downward).
                let pc = SIMD4<Float>((Float(u) - cx) / fx * d, -(Float(v) - cy) / fy * d, -d, 1)
                let pw = T * pc
                let dx = pw.x - cam.x, dz = pw.z - cam.z
                let f = dx * heading.x + dz * heading.y
                let lateral = abs(dx * heading.y - dz * heading.x)
                guard f > 0.2, f < maxForward, lateral <= corridorHalfWidth else { continue }
                out.append(GroundSample(forward: f, height: pw.y))  // ARKit world +y is up (gravity-aligned)
            }
        }
        return DepthFrameOutput(samples: out, headingOK: true, fingerprint: fingerprint)
    }
}
