import CoreLocation
import Foundation
import UIKit

/// One confirmed step/drop the user walked past.
struct Hazard: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case pending, confirmed, dismissed }

    var id = UUID()
    var date: Date
    var up: Bool
    var heightCm: Double          // always positive; direction in `up`
    var distanceM: Double
    var isStairs: Bool
    var latitude: Double?
    var longitude: Double?
    var photo: String?
    var status: Status = .pending
    /// Height measured with a tape, for validating the LiDAR reading.
    var tapeCm: Double?

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var title: String {
        isStairs ? (up ? "Stairs up" : "Stairs down") : (up ? "Step up" : "Step down")
    }

    /// LiDAR minus tape, in cm.
    var errorCm: Double? { tapeCm.map { heightCm - $0 } }
}

/// Persists hazards as JSON + JPEG thumbnails in the app's Documents folder. Main thread only.
final class HazardStore: ObservableObject {
    @Published private(set) var hazards: [Hazard] = []
    @Published private(set) var walkStart = Date()

    private let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var file: URL { dir.appendingPathComponent("hazards.json") }

    init() { load() }

    var walkHazards: [Hazard] { hazards.filter { $0.date >= walkStart } }

    func record(_ r: DetectionResult, location: CLLocation?, photo: Data?) {
        let up = r.kind == .stepUp
        let now = Date()
        // The same edge is usually confirmed several times while approaching it; keep one.
        if let last = hazards.first, last.up == up, now.timeIntervalSince(last.date) < 15 {
            if let location, let c = last.coordinate {
                if location.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) < 4 { return }
            } else {
                return
            }
        }
        var h = Hazard(date: now, up: up, heightCm: Double(abs(r.heightCm)), distanceM: Double(r.distanceM),
                       isStairs: r.isStairs,
                       latitude: location?.coordinate.latitude, longitude: location?.coordinate.longitude)
        if let photo {
            let name = h.id.uuidString + ".jpg"
            if (try? photo.write(to: dir.appendingPathComponent(name))) != nil { h.photo = name }
        }
        hazards.insert(h, at: 0)
        save()
    }

    func setStatus(_ id: UUID, _ status: Hazard.Status) {
        update(id) { $0.status = status }
    }

    func setTape(_ id: UUID, _ cm: Double?) {
        update(id) { $0.tapeCm = cm }
    }

    func delete(_ id: UUID) {
        if let h = hazards.first(where: { $0.id == id }), let p = h.photo {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(p))
        }
        hazards.removeAll { $0.id == id }
        save()
    }

    func image(for h: Hazard) -> UIImage? {
        h.photo.flatMap { UIImage(contentsOfFile: dir.appendingPathComponent($0).path) }
    }

    func newWalk() { walkStart = Date() }

    private func update(_ id: UUID, _ change: (inout Hazard) -> Void) {
        guard let i = hazards.firstIndex(where: { $0.id == id }) else { return }
        change(&hazards[i])
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([Hazard].self, from: data) else { return }
        hazards = list
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hazards) { try? data.write(to: file, options: .atomic) }
    }
}

/// Summary numbers for a walk, shared by the summary screen and the family report.
struct WalkSummary {
    var start: Date
    var detected: Int
    var confirmed: Int
    var dismissed: Int
    var stairs: Int
    var largestDropCm: Double?
    var largestStepUpCm: Double?
    var meanAbsErrorCm: Double?
    var validated: Int

    init(start: Date, hazards: [Hazard]) {
        self.start = start
        let real = hazards.filter { $0.status != .dismissed }
        detected = hazards.count
        confirmed = hazards.filter { $0.status == .confirmed }.count
        dismissed = hazards.filter { $0.status == .dismissed }.count
        stairs = real.filter { $0.isStairs }.count
        largestDropCm = real.filter { !$0.up }.map(\.heightCm).max()
        largestStepUpCm = real.filter { $0.up }.map(\.heightCm).max()
        let errors = hazards.compactMap(\.errorCm)
        validated = errors.count
        meanAbsErrorCm = errors.isEmpty ? nil : errors.map(abs).reduce(0, +) / Double(errors.count)
    }

    var shareText: String {
        let minutes = max(1, Int(Date().timeIntervalSince(start) / 60))
        var lines = ["MindTheStep walk summary (\(minutes) min)",
                     "• \(detected - dismissed) steps or drops flagged, \(confirmed) confirmed"]
        if stairs > 0 { lines.append("• \(stairs) staircases") }
        if let d = largestDropCm { lines.append(String(format: "• Largest drop: %.0f cm", d)) }
        if let u = largestStepUpCm { lines.append(String(format: "• Largest step up: %.0f cm", u)) }
        if let e = meanAbsErrorCm { lines.append(String(format: "• LiDAR vs tape: ±%.1f cm average (%d checks)", e, validated)) }
        return lines.joined(separator: "\n")
    }
}
