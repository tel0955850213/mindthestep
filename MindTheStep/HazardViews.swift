import MapKit
import SwiftUI

/// Hazard Memory: walk summary for family, the hazard log, and a map.
struct HazardSheet: View {
    @ObservedObject var store: HazardStore
    @State private var tab = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $tab) {
                    Text("Summary").tag(0)
                    Text("Hazards").tag(1)
                    Text("Map").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()

                switch tab {
                case 0: SummaryView(store: store)
                case 1: HazardList(store: store)
                default: HazardMap(store: store)
                }
            }
            .navigationTitle("Hazard Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Summary (Family report)

struct SummaryView: View {
    @ObservedObject var store: HazardStore

    var body: some View {
        let summary = WalkSummary(start: store.walkStart, hazards: store.walkHazards)
        ScrollView {
            VStack(spacing: 16) {
                SummaryCard(summary: summary)
                ShareLink(item: renderImage(summary), message: Text(summary.shareText),
                          preview: SharePreview("MindTheStep walk summary", image: renderImage(summary))) {
                    Label("Share with family", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Palette.clear, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                }
                Button {
                    store.newWalk()
                } label: {
                    Label("Start a new walk", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Text("Location and photos stay on this iPhone unless you share them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
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
                    tile(summary.largestDropCm.map { String(format: "%.0f cm", $0) } ?? "—", "largest drop", Palette.danger)
                    tile("\(summary.stairs)", "staircases", Palette.info)
                }
            }
            if let e = summary.meanAbsErrorCm {
                Label(String(format: "LiDAR vs tape measure: ±%.1f cm average over %d checks", e, summary.validated),
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

    private func tile(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 30, weight: .black, design: .rounded).monospacedDigit())
            Text(label).font(.caption.weight(.semibold)).opacity(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - List

struct HazardList: View {
    @ObservedObject var store: HazardStore

    var body: some View {
        if store.hazards.isEmpty {
            ContentUnavailableView("No hazards yet", systemImage: "figure.walk",
                                   description: Text("Steps and drops you pass are saved here automatically."))
        } else {
            List {
                ForEach(store.hazards) { h in
                    NavigationLink { HazardDetail(store: store, id: h.id) } label: { HazardRow(store: store, hazard: h) }
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
            .listStyle(.plain)
        }
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
                Text(String(format: "%.0f cm", hazard.heightCm) + (hazard.tapeCm.map { String(format: " · tape %.0f cm", $0) } ?? ""))
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
        case .pending: ("new", Palette.caution)
        case .confirmed: ("confirmed", Palette.clear)
        case .dismissed: ("false alarm", Palette.unknown)
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
                    LabeledContent("Warned at", value: String(format: "%.1f m ahead", h.distanceM))
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

// MARK: - Map

struct HazardMap: View {
    @ObservedObject var store: HazardStore

    var body: some View {
        let pins = store.hazards.filter { $0.status != .dismissed && $0.coordinate != nil }
        Map {
            UserAnnotation()
            ForEach(pins) { h in
                Annotation(String(format: "%.0f cm", h.heightCm), coordinate: h.coordinate!) {
                    Image(systemName: h.up ? "arrow.up" : "arrow.down")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(h.heightCm > 15 ? Palette.danger : Palette.caution, in: Circle())
                }
            }
        }
        .overlay(alignment: .bottom) {
            if pins.isEmpty {
                Text("Hazards with a location appear here.")
                    .font(.footnote).padding(10)
                    .background(.ultraThinMaterial, in: Capsule()).padding()
            }
        }
    }
}
