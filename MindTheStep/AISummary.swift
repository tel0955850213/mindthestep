import Foundation
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Turns a walk into a short, warm note for the caregiver, written by Apple's on-device model.
/// Nothing leaves the phone to write it. Facts come only from the hazard log.
enum WalkNarrator {
    /// Plain facts the model is allowed to use. Kept separate so it can be unit-tested.
    static func facts(summary: WalkSummary, hazards: [Hazard], now: Date = Date()) -> String {
        let minutes = max(1, Int(now.timeIntervalSince(summary.start) / 60))
        let real = hazards.filter { $0.status != .dismissed }
        var lines = ["Walk length: about \(minutes) minutes.",
                     "Steps or drops warned about: \(real.count).",
                     "Staircases: \(summary.stairs)."]
        if let d = summary.largestDropCm { lines.append(String(format: "Largest drop: %.0f cm.", d)) }
        if let u = summary.largestStepUpCm { lines.append(String(format: "Largest step up: %.0f cm.", u)) }
        let big = real.filter { $0.heightCm > 15 }.count
        lines.append("Hazards taller than 15 cm: \(big).")
        let timeFmt = Date.FormatStyle(date: .omitted, time: .shortened)
        for h in real.prefix(8).reversed() {
            lines.append("- \(h.date.formatted(timeFmt)): \(h.title.lowercased()), \(Int(h.heightCm.rounded())) cm, warned \(String(format: "%.1f", h.distanceM)) m ahead.")
        }
        lines.append("Every hazard was warned about before she reached it. No fall was detected or reported.")
        return lines.joined(separator: "\n")
    }

    static let instructions = """
    You write a short update for a family caregiver about their older parent's walk, \
    from a step-warning app. Use only the facts provided; never invent places, names, \
    times or numbers. Write 2 to 3 short, warm, calm sentences in plain English. \
    Mention the most important hazard and end with one practical, gentle suggestion. \
    Do not give medical advice. Do not mention location.
    """

    /// Template used when Apple Intelligence isn't available, so the feature still works.
    static func fallback(summary: WalkSummary, hazards: [Hazard]) -> String {
        let real = hazards.filter { $0.status != .dismissed }
        guard !real.isEmpty else { return "A calm walk today. No steps or drops needed a warning." }
        var s = "She was warned about \(real.count) step\(real.count == 1 ? "" : "s") or drops on today's walk"
        if let d = summary.largestDropCm { s += String(format: ", the largest a %.0f cm drop", d) }
        s += ". Every one was flagged before she reached it."
        if summary.stairs > 0 { s += " Her route included \(summary.stairs) staircase\(summary.stairs == 1 ? "" : "s"); a handrail helps." }
        return s
    }

    enum Outcome { case ai(String), fallback(String, reason: String) }

    static func write(summary: WalkSummary, hazards: [Hazard]) async -> Outcome {
        let template = fallback(summary: summary, hazards: hazards)
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard case .available = model.availability else {
                return .fallback(template, reason: "Apple Intelligence isn't ready on this iPhone")
            }
            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: "Facts about today's walk:\n" + facts(summary: summary, hazards: hazards))
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? .fallback(template, reason: "The model returned nothing") : .ai(text)
            } catch {
                return .fallback(template, reason: "On-device AI error")
            }
        }
        #endif
        return .fallback(template, reason: "Needs iOS 26 or later")
    }
}

/// Report card: write the caregiver note with on-device AI, then send or share it.
struct AISummaryCard: View {
    @ObservedObject var store: HazardStore
    @ObservedObject var family: FamilyNotifier
    @State private var text: String?
    @State private var isAI = false
    @State private var note: String?
    @State private var working = false
    @State private var sendState: String?

    var body: some View {
        let summary = WalkSummary(start: store.walkStart, hazards: store.walkHazards)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "apple.intelligence")
                    .font(.headline)
                    .foregroundStyle(LinearGradient(colors: [.orange, .pink, .purple, .blue],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("Note for \(family.name)").font(.headline)
                Spacer()
                Text(isAI ? "On-device AI" : "Private · on this iPhone")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }

            if let text {
                HStack(alignment: .top, spacing: 10) {
                    FamilyAvatar(name: family.name, size: 32)
                    Text(text)
                        .font(.body)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .textSelection(.enabled)
                }
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button {
                        sendState = "Sending…"
                        Task {
                            let ok = await family.send(text, title: "Today's walk")
                            await MainActor.run {
                                family.log(text, delivered: ok)
                                sendState = ok ? "Sent to \(family.name) ✓" : "Couldn't send"
                            }
                        }
                    } label: {
                        Label("Send to \(family.name)", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.clear)
                    ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button { generate(summary) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                        .disabled(working)
                }
                if let sendState { Text(sendState).font(.caption).foregroundStyle(.secondary) }
            } else {
                Text("Turn today's walk into a short, friendly note for \(family.name). Written on this iPhone; nothing is uploaded to write it.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button { generate(summary) } label: {
                    HStack {
                        if working { ProgressView().tint(.white) }
                        Label(working ? "Writing…" : "Write with Apple Intelligence", systemImage: "sparkles")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(working)
            }
        }
    }

    private func generate(_ summary: WalkSummary) {
        working = true
        sendState = nil
        let hazards = store.walkHazards
        Task {
            let outcome = await WalkNarrator.write(summary: summary, hazards: hazards)
            await MainActor.run {
                working = false
                switch outcome {
                case .ai(let t): text = t; isAI = true; note = "Written by Apple's on-device model from today's hazard log."
                case .fallback(let t, let reason): text = t; isAI = false; note = "\(reason). Showing a standard summary."
                }
            }
        }
    }
}
