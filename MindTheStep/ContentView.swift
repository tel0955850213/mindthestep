import ARKit
import RealityKit
import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        ZStack {
            if model.supported {
                CameraView(session: model.session).ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                Text("This iPhone has no LiDAR.\nMindTheStep needs an iPhone Pro (12 Pro or later).")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding()
            }
            VStack(spacing: 10) {
                StatusBanner(result: model.result, alert: model.lastAlert, alertTime: model.lastAlertTime)
                Spacer()
                ProfileView(result: model.result, thresholdCm: Float(model.thresholdCm))
                    .frame(height: 110)
                DiagnosticsView(model: model)
            }
            .padding()
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            model.start()
        }
    }
}

struct CameraView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = session
        view.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disablePersonOcclusion,
                              .disableGroundingShadows, .disableHDR]
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

struct StatusBanner: View {
    let result: DetectionResult
    let alert: DetectionResult?
    let alertTime: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
            let recentAlert = alert.flatMap { a in
                (alertTime.map { ctx.date.timeIntervalSince($0) < 2.5 } ?? false) ? a : nil
            }
            let shown = recentAlert ?? result
            let style = Self.style(for: shown)
            VStack(spacing: 4) {
                Text(style.title)
                    .font(.system(size: 38, weight: .heavy, design: .rounded))
                Text(style.subtitle)
                    .font(.title3.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(style.color.opacity(0.88), in: RoundedRectangle(cornerRadius: 22))
            .scaleEffect(recentAlert != nil ? 1.04 : 1)
            .animation(.spring(duration: 0.25), value: recentAlert != nil)
        }
    }

    static func style(for r: DetectionResult) -> (title: String, subtitle: String, color: Color) {
        let cm = Int(abs(r.heightCm).rounded())
        let dist = String(format: "%.1f m ahead", r.distanceM)
        switch r.kind {
        case .stepDown: return ("STEP DOWN", "\(cm) cm · \(dist)", abs(r.heightCm) > 15 ? .red : .orange)
        case .stepUp: return ("STEP UP", "\(cm) cm · \(dist)", abs(r.heightCm) > 15 ? .red : .orange)
        case .ramp: return ("RAMP", String(format: "%.0f%% slope", r.slopePercent), .blue)
        case .unknown: return ("CAN'T SEE GROUND", r.reason, .gray)
        case .clear: return ("CLEAR", "Path ahead looks level", .green)
        }
    }
}

/// Live ground-height profile ahead (cm vs metres), with the alert threshold band.
struct ProfileView: View {
    let result: DetectionResult
    let thresholdCm: Float

    var body: some View {
        Canvas { ctx, size in
            let maxCm: Float = 30
            let span = result.binSize * Float(max(result.profileCm.count, 1))
            func x(_ f: Float) -> CGFloat { CGFloat((f - result.minForward) / span) * size.width }
            func y(_ cm: Float) -> CGFloat {
                let clamped = max(-maxCm, min(maxCm, cm))
                return size.height / 2 - CGFloat(clamped / maxCm) * size.height / 2
            }
            var band = Path()
            band.addRect(CGRect(x: 0, y: y(thresholdCm), width: size.width, height: y(-thresholdCm) - y(thresholdCm)))
            ctx.fill(band, with: .color(.white.opacity(0.08)))
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: y(0)))
            zero.addLine(to: CGPoint(x: size.width, y: y(0)))
            ctx.stroke(zero, with: .color(.white.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

            var line = Path()
            var penDown = false
            for (i, v) in result.profileCm.enumerated() {
                let f = result.minForward + (Float(i) + 0.5) * result.binSize
                guard let v else { penDown = false; continue }
                let p = CGPoint(x: x(f), y: y(v))
                if penDown { line.addLine(to: p) } else { line.move(to: p); penDown = true }
            }
            ctx.stroke(line, with: .color(.yellow), lineWidth: 3)

            if result.kind == .stepUp || result.kind == .stepDown {
                var marker = Path()
                marker.move(to: CGPoint(x: x(result.distanceM), y: 0))
                marker.addLine(to: CGPoint(x: x(result.distanceM), y: size.height))
                ctx.stroke(marker, with: .color(.red), lineWidth: 2)
            }
        }
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topLeading) {
            Text("ground ahead · 0.3–2.5 m · ±30 cm")
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.7))
                .padding(6)
        }
    }
}

struct DiagnosticsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                GridRow {
                    stat("depth fps", String(format: "%.0f", model.depthFPS))
                    stat("proc", String(format: "%.1f ms", model.processingMs))
                    stat("alert lag", String(format: "%.0f ms", model.alertLatencyMs))
                }
                GridRow {
                    stat("tracking", model.tracking)
                    stat("points", "\(model.points)")
                    stat("conf", String(format: "%.0f%%", model.result.confidence * 100))
                }
            }
            HStack {
                Stepper("Alert ≥ \(Int(model.thresholdCm)) cm", value: $model.thresholdCm, in: 3...20, step: 1)
                Toggle("Voice", isOn: $model.speechOn).fixedSize()
            }
            .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption2).foregroundStyle(.white.opacity(0.6))
            Text(value).font(.callout.monospacedDigit().weight(.semibold))
        }
    }
}
