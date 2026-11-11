import MapKit
import SwiftUI

// MARK: - Report tab

/// Today's walk at a glance, shareable with family, plus every hazard to review.
struct ReportTab: View {
    @ObservedObject var store: HazardStore
    @ObservedObject var family: FamilyNotifier
    @State private var confirmClear = false

    var body: some View {
        let summary = WalkSummary(start: store.walkStart, hazards: store.walkHazards)
        NavigationStack {
            List {
                Section {
                    SummaryCard(summary: summary)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    AISummaryCard(store: store, family: family)
                }
                Section {
                    ShareLink(item: renderImage(summary), message: Text(summary.shareText),
                              preview: SharePreview("MindTheStep walk summary", image: renderImage(summary))) {
                        Label("Share report with family", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .listRowBackground(Palette.clear)
                    .foregroundStyle(.white)
                }
                Section {
                    if store.hazards.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "figure.walk").font(.largeTitle).foregroundStyle(.secondary)
                            Text("No hazards yet").font(.headline)
                            Text("Steps and drops you pass are saved here automatically.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    } else {
                        ForEach(store.hazards) { h in
                            NavigationLink { HazardDetail(store: store, id: h.id) } label: {
                                HazardRow(store: store, hazard: h)
                            }
                            .swipeActions(edge: .leading) {
                                Button { store.setStatus(h.id, .confirmed) } label: { Label("Confirm", systemImage: "checkmark") }
                                    .tint(Palette.clear)
                            }
                            .swipeActions(edge: .trailing) {
                                Button { store.setStatus(h.id, .dismissed) } label: { Label("Not real", systemImage: "xmark") }
                                    .tint(Palette.unknown)
                                Button(role: .destructive) { store.delete(h.id) } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    }
                } header: {
                    Text("Hazards")
                } footer: {
                    if !store.hazards.isEmpty {
                        Text("Swipe right to confirm, left for a false alarm. Tap one to check it against a tape measure.")
                    }
                }
                Section {
                    Button { store.newWalk() } label: { Label("Start a new walk", systemImage: "arrow.counterclockwise") }
                    Button(role: .destructive) { confirmClear = true } label: { Label("Clear all hazards", systemImage: "trash") }
                } footer: {
                    Text("Location and photos stay on this iPhone unless you share them.")
                }
            }
            .navigationTitle("Report")
            .confirmationDialog("Delete every saved hazard and photo?", isPresented: $confirmClear,
                                titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { store.clearAll() }
            }
        }
    }

    @MainActor private func renderImage(_ s: WalkSummary) -> Image {
        let renderer = ImageRenderer(content: SummaryCard(summary: s).frame(width: 360).padding(12)
            .background(Color.black))
        renderer.scale = 3
        return renderer.uiImage.map { Image(uiImage: $0) } ?? Image(systemName: "figure.walk")
    }
}

struct SummaryCard: View {
    let summary: WalkSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "figure.walk")
                Text("Today's walk").font(.system(.title3, design: .rounded).weight(.heavy))
                Spacer()
                Text(summary.start, style: .time).font(.subheadline).opacity(0.7)
            }
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    tile("\(summary.detected - summary.dismissed)", "steps & drops", Palette.caution)
                    tile("\(summary.confirmed)", "confirmed", Palette.clear)
                }
                GridRow {
                    tile(summary.largestDropCm.map { L("\(Int($0.rounded())) cm") } ?? "—", "largest drop", Palette.danger)
                    tile("\(summary.stairs)", "staircases", Palette.info)
                }
            }
            if let e = summary.meanAbsErrorCm {
                Label(L("LiDAR vs tape measure: ±\(String(format: "%.1f", e)) cm average over \(summary.validated) checks"),
                      systemImage: "ruler")
                    .font(.footnote.weight(.semibold))
            }
            Text("Measured on-device with iPhone LiDAR · MindTheStep")
                .font(.caption2).opacity(0.6)
        }
        .foregroundStyle(.white)
        .padding(18)
        .background(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.08)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func tile(_ value: String, _ label: LocalizedStringKey, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 30, weight: .black, design: .rounded).monospacedDigit())
            Text(label).font(.caption.weight(.semibold)).opacity(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct HazardRow: View {
    @ObservedObject var store: HazardStore
    let hazard: Hazard

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let img = store.image(for: hazard) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Image(systemName: hazard.up ? "arrow.up" : "arrow.down").font(.title2)
                }
            }
            .frame(width: 60, height: 60)
            .background(Color(white: 0.2))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(hazard.title).font(.headline)
                    StatusChip(status: hazard.status)
                }
                Text(L("\(Int(hazard.heightCm.rounded())) cm") + (hazard.tapeCm.map { " · " + L("tape \(Int($0.rounded())) cm") } ?? ""))
                    .font(.subheadline.monospacedDigit())
                Text(hazard.date, style: .time).font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(hazard.status == .dismissed ? 0.5 : 1)
    }
}

struct StatusChip: View {
    let status: Hazard.Status
    var body: some View {
        let (text, color): (String, Color) = switch status {
        case .pending: (L("new"), Palette.caution)
        case .confirmed: (L("confirmed"), Palette.clear)
        case .dismissed: (L("false alarm"), Palette.unknown)
        }
        Text(text).font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.3), in: Capsule())
    }
}

struct HazardDetail: View {
    @ObservedObject var store: HazardStore
    let id: UUID
    @State private var tapeText = ""

    var body: some View {
        if let h = store.hazards.first(where: { $0.id == id }) {
            Form {
                if let img = store.image(for: h) {
                    Section { Image(uiImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12)) }
                }
                Section("Detected") {
                    LabeledContent("Type", value: h.title)
                    LabeledContent("LiDAR height", value: String(format: "%.1f cm", h.heightCm))
                    LabeledContent("Warned at", value: L("\(String(format: "%.1f", h.distanceM)) m ahead"))
                    LabeledContent("Time") { Text(h.date, style: .time) }
                }
                Section {
                    Picker("Is it real?", selection: Binding(get: { h.status }, set: { store.setStatus(id, $0) })) {
                        Text("Unreviewed").tag(Hazard.Status.pending)
                        Text("Confirmed").tag(Hazard.Status.confirmed)
                        Text("False alarm").tag(Hazard.Status.dismissed)
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    HStack {
                        TextField("Tape-measured height", text: $tapeText)
                            .keyboardType(.decimalPad)
                        Text("cm").foregroundStyle(.secondary)
                        Button("Save") { store.setTape(id, Double(tapeText)) }
                    }
                    if let e = h.errorCm {
                        LabeledContent("LiDAR error", value: String(format: "%+.1f cm", e))
                    }
                } header: {
                    Text("Validate")
                } footer: {
                    Text("Measure the real step with a tape to check the LiDAR reading.")
                }
            }
            .navigationTitle(h.title)
            .onAppear { tapeText = h.tapeCm.map { String(format: "%.1f", $0) } ?? "" }
        }
    }
}

// MARK: - Map tab

struct MapTab: View {
    @ObservedObject var store: HazardStore

    var body: some View {
        let pins = store.hazards.filter { $0.status != .dismissed && $0.coordinate != nil }
        NavigationStack {
            Map {
                UserAnnotation()
                ForEach(pins) { h in
                    Annotation(L("\(Int(h.heightCm.rounded())) cm"), coordinate: h.coordinate!) {
                        Image(systemName: h.up ? "arrow.up" : "arrow.down")
                            .font(.caption.weight(.black))
                            .foregroundStyle(.white)
                            .padding(7)
                            .background(h.heightCm > 15 ? Palette.danger : Palette.caution, in: Circle())
                    }
                }
            }
            .overlay(alignment: .top) {
                HStack(spacing: 14) {
                    legend(Palette.danger, "over 15 cm")
                    legend(Palette.caution, "8–15 cm")
                    Text("\(pins.count) saved").foregroundStyle(.secondary)
                }
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
            }
            .navigationTitle("Hazard map")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func legend(_ color: Color, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(text)
        }
    }
}

// MARK: - Family tab

struct FamilyTab: View {
    @ObservedObject var family: FamilyNotifier

    var body: some View {
        NavigationStack {
            FamilySettingsView(family: family)
                .navigationTitle("Family")
        }
    }
}
