import ARKit
import RealityKit
import SwiftUI

// MARK: - Visual language

/// One place that maps a detection to words, colour and icon, so every surface agrees.
struct HazardStyle {
    var title: String
    var value: String?      // the big number, e.g. "17 cm"
    var detail: String
    var icon: String
    var color: Color
    var isAlert: Bool

    init(_ r: DetectionResult) {
        let cm = Int(abs(r.heightCm).rounded())
        let dist = String(format: "%.1f m ahead", r.distanceM)
        switch r.kind {
        case .stepDown, .stepUp:
            let down = r.kind == .stepDown
            title = r.isStairs ? (down ? "Stairs down" : "Stairs up") : (down ? "Step down" : "Step up")
            value = "\(cm) cm"
            detail = dist
            icon = r.isStairs ? "figure.stairs" : (down ? "arrow.down" : "arrow.up")
            color = abs(r.heightCm) > 15 ? Palette.danger : Palette.caution
            isAlert = true
        case .ramp:
            title = r.slopePercent > 0 ? "Ramp up" : "Ramp down"
            value = String(format: "%.0f%%", abs(r.slopePercent))
            detail = "Gentle slope ahead"
            icon = r.slopePercent > 0 ? "arrow.up.right" : "arrow.down.right"
            color = Palette.info
            isAlert = false
        case .unknown:
            let tilt = r.reason.contains("Tilt")
            title = tilt ? "Tilt phone forward" : "Can't see the ground"
            value = nil
            detail = tilt ? "Aim about 1–2 m ahead of your feet" : r.reason
            icon = tilt ? "iphone.gen3" : "eye.slash.fill"
            color = Palette.unknown
            isAlert = false
        case .clear:
            title = "Path clear"
            value = nil
            detail = "Level ground ahead"
            icon = "checkmark"
            color = Palette.clear
            isAlert = false
        }
    }
}

enum Palette {
    static let danger = Color(red: 0.93, green: 0.20, blue: 0.20)
    static let caution = Color(red: 0.98, green: 0.58, blue: 0.10)
    static let clear = Color(red: 0.16, green: 0.72, blue: 0.48)
    static let info = Color(red: 0.25, green: 0.52, blue: 0.96)
    static let unknown = Color(red: 0.42, green: 0.45, blue: 0.52)
}

// MARK: - Root

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.15)) { ctx in
            let recentAlert = model.lastAlert.flatMap { a in
                (model.lastAlertTime.map { ctx.date.timeIntervalSince($0) < 2.5 } ?? false) ? a : nil
            }
            let shown = recentAlert ?? model.result
            let style = HazardStyle(shown)

            ZStack {
                if model.supported {
                    CameraView(session: model.session, marker: model.markerAnchor).ignoresSafeArea()
                } else {
                    Color.black.ignoresSafeArea()
                }
                LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.75)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                AlertGlow(color: style.color, active: recentAlert != nil)

                VStack(spacing: 12) {
                    TopBar(model: model)
                    Spacer()
                    if !model.supported {
                        NoLidarCard()
                    }
                    if model.showDiagnostics {
                        DiagnosticsDrawer(model: model)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    HazardCard(style: style, emphasized: recentAlert != nil)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .animation(.spring(duration: 0.3), value: model.showDiagnostics)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            model.start()
        }
    }
}

// MARK: - Camera

struct CameraView: UIViewRepresentable {
    let session: ARSession
    let marker: AnchorEntity

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = session
        view.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disablePersonOcclusion,
                              .disableGroundingShadows, .disableHDR]
        view.scene.addAnchor(marker)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

// MARK: - Pieces

struct TopBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "figure.walk")
                    .font(.headline.weight(.bold))
                Text("MindTheStep")
                    .font(.system(.headline, design: .rounded).weight(.heavy))
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(model.tracking == "normal" ? Palette.clear : Palette.caution)
                    .frame(width: 8, height: 8)
                Text("LiDAR \(Int(model.depthFPS.rounded())) fps")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityLabel("LiDAR running at \(Int(model.depthFPS)) frames per second")

            RoundButton(icon: model.speechOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                        label: model.speechOn ? "Mute voice" : "Unmute voice") {
                model.speechOn.toggle()
            }
            RoundButton(icon: "chart.xyaxis.line",
                        label: model.showDiagnostics ? "Hide diagnostics" : "Show diagnostics",
                        active: model.showDiagnostics) {
                model.showDiagnostics.toggle()
            }
        }
        .foregroundStyle(.white)
    }
}

struct RoundButton: View {
    let icon: String
    let label: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .frame(width: 38, height: 38)
                .background(active ? AnyShapeStyle(.white.opacity(0.3)) : AnyShapeStyle(.ultraThinMaterial),
                            in: Circle())
        }
        .accessibilityLabel(label)
    }
}

/// The one thing a walking senior needs to read: what, how big, how far.
struct HazardCard: View {
    let style: HazardStyle
    let emphasized: Bool

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(.white.opacity(0.22))
                Image(systemName: style.icon)
                    .font(.system(size: 34, weight: .black))
            }
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 2) {
                Text(style.title)
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let value = style.value {
                    Text(value)
                        .font(.system(size: 52, weight: .black, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
                Text(style.detail)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .opacity(0.9)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(style.color.gradient.opacity(0.94), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 1))
        .shadow(color: style.color.opacity(emphasized ? 0.7 : 0.3), radius: emphasized ? 24 : 10)
        .scaleEffect(emphasized ? 1.03 : 1)
        .animation(.spring(duration: 0.25), value: emphasized)
        .animation(.easeInOut(duration: 0.2), value: style.title)
        .accessibilityElement(children: .combine)
    }
}

/// Coloured edge glow around the screen while an alert is fresh.
struct AlertGlow: View {
    let color: Color
    let active: Bool
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: 48, style: .continuous)
            .strokeBorder(color, lineWidth: active ? (pulse ? 16 : 8) : 0)
            .blur(radius: 6)
            .ignoresSafeArea()
            .opacity(active ? 1 : 0)
            .animation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true), value: pulse)
            .animation(.easeOut(duration: 0.3), value: active)
            .onAppear { pulse = true }
            .allowsHitTesting(false)
    }
}

struct NoLidarCard: View {
    var body: some View {
        Text("This iPhone has no LiDAR.\nMindTheStep needs an iPhone Pro (12 Pro or later).")
            .multilineTextAlignment(.center)
            .font(.headline)
            .foregroundStyle(.white)
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct DiagnosticsDrawer: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProfileView(result: model.result, thresholdCm: Float(model.thresholdCm))
                .frame(height: 100)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    stat("depth fps", String(format: "%.0f", model.depthFPS))
                    stat("processing", String(format: "%.1f ms", model.processingMs))
                    stat("alert lag", String(format: "%.0f ms", model.alertLatencyMs))
                }
                GridRow {
                    stat("tracking", model.tracking)
                    stat("points", "\(model.points)")
                    stat("confidence", String(format: "%.0f%%", model.result.confidence * 100))
                }
            }
            Stepper("Alert at ≥ \(Int(model.thresholdCm)) cm", value: $model.thresholdCm, in: 3...20, step: 1)
                .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label.uppercased()).font(.system(size: 9, weight: .bold)).opacity(0.6)
            Text(value).font(.callout.monospacedDigit().weight(.semibold))
        }
    }
}

/// Live ground-height profile ahead (cm vs metres), with the alert threshold band.
struct ProfileView: View {
    let result: DetectionResult
    let thresholdCm: Float

    var body: some View {
        Canvas { ctx, size in
            let maxCm: Float = 40
            let span = result.binSize * Float(max(result.profileCm.count, 1))
            func x(_ f: Float) -> CGFloat { CGFloat((f - result.minForward) / span) * size.width }
            func y(_ cm: Float) -> CGFloat {
                let clamped = max(-maxCm, min(maxCm, cm))
                return size.height / 2 - CGFloat(clamped / maxCm) * size.height / 2
            }
            var band = Path()
            band.addRect(CGRect(x: 0, y: y(thresholdCm), width: size.width,
                                height: y(-thresholdCm) - y(thresholdCm)))
            ctx.fill(band, with: .color(.white.opacity(0.08)))
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: y(0)))
            zero.addLine(to: CGPoint(x: size.width, y: y(0)))
            ctx.stroke(zero, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

            var line = Path()
            var penDown = false
            for (i, v) in result.profileCm.enumerated() {
                let f = result.minForward + (Float(i) + 0.5) * result.binSize
                guard let v else { penDown = false; continue }
                let p = CGPoint(x: x(f), y: y(v))
                if penDown { line.addLine(to: p) } else { line.move(to: p); penDown = true }
            }
            ctx.stroke(line, with: .color(.yellow), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

            if result.kind == .stepUp || result.kind == .stepDown {
                var marker = Path()
                marker.move(to: CGPoint(x: x(result.distanceM), y: 0))
                marker.addLine(to: CGPoint(x: x(result.distanceM), y: size.height))
                ctx.stroke(marker, with: .color(Palette.danger), lineWidth: 2)
            }
        }
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topLeading) {
            Text("GROUND AHEAD · 0.3–2.5 m · ±40 cm")
                .font(.system(size: 9, weight: .bold).monospaced())
                .opacity(0.6)
                .padding(6)
        }
        .overlay(alignment: .bottomTrailing) {
            Text("on-device LiDAR · no cloud")
                .font(.system(size: 9, weight: .bold))
                .opacity(0.6)
                .padding(6)
        }
    }
}
