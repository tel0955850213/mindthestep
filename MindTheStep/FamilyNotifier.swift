import Foundation
import PhotosUI
import SwiftUI
import UIKit

/// The family member who receives alerts.
struct FamilyContact: Equatable {
    var name: String
}

/// Family member's photo (Documents/FamilyAvatar.png, chosen in the Family tab), else their initial.
struct FamilyAvatar: View {
    let name: String
    var size: CGFloat = 50
    @AppStorage("family.avatarVersion") private var version = 0

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FamilyAvatar.png")
    }

    var body: some View {
        let photo = version >= 0 ? UIImage(contentsOfFile: Self.fileURL.path) : nil
        Group {
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill()
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LinearGradient(colors: [Palette.info, Palette.clear], startPoint: .top, endPoint: .bottom))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1.5))
    }
}

/// What the top banner shows after an alert goes to family.
struct FamilyNotice: Equatable {
    enum State: Equatable { case sending, delivered, failed }
    var id = UUID()
    var state: State
    var message: String
}

/// Sends real push notifications to a family member through ntfy.sh (free, no account).
/// The family member opens the topic link in a browser or the ntfy app to receive alerts.
/// Only the step type, height and time are sent. No location, no photo.
final class FamilyNotifier: ObservableObject {
    @AppStorage("family.contactName") var name = L("Daughter")
    @AppStorage("family.enabled") var enabled = true
    @AppStorage("family.minCm") var minCm = 12.0
    @AppStorage("family.topic") var topic = ""

    private var lastSent: Date?
    let cooldown: TimeInterval = 30

    /// Alerts sent to family, newest first (kept on device).
    struct SentAlert: Identifiable, Codable, Equatable {
        var id = UUID()
        var date: Date
        var text: String
        var delivered: Bool
    }
    @Published private(set) var sent: [SentAlert] = []

    func log(_ text: String, delivered: Bool) {
        sent.insert(SentAlert(date: Date(), text: text, delivered: delivered), at: 0)
        if sent.count > 30 { sent.removeLast(sent.count - 30) }
        if let data = try? JSONEncoder().encode(sent) { UserDefaults.standard.set(data, forKey: "family.sent") }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "family.sent"),
           let list = try? JSONDecoder().decode([SentAlert].self, from: data) { sent = list }
        if topic.isEmpty {
            let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
            topic = "mindthestep-" + String((0..<10).map { _ in chars.randomElement()! })
        }
    }

    var contact: FamilyContact { FamilyContact(name: name) }
    var link: URL { URL(string: "https://ntfy.sh/\(topic)")! }

    func shouldNotify(_ r: DetectionResult) -> Bool {
        guard enabled, r.kind == .stepUp || r.kind == .stepDown, Double(abs(r.heightCm)) >= minCm else { return false }
        if let lastSent, Date().timeIntervalSince(lastSent) < cooldown { return false }
        return true
    }

    func message(for r: DetectionResult) -> String {
        let cm = Int(abs(r.heightCm).rounded())
        let up = r.kind == .stepUp
        let what = r.isStairs ? (up ? L("stairs going up") : L("stairs going down"))
                              : (up ? L("a \(cm) cm step up") : L("a \(cm) cm step down"))
        let time = Date().formatted(date: .omitted, time: .shortened)
        return L("MindTheStep warned about \(what) at \(time). Alert given in time.")
    }

    /// Returns true when ntfy accepted the message.
    func send(_ text: String, title: String = L("MindTheStep alert")) async -> Bool {
        lastSent = Date()
        var req = URLRequest(url: link)
        req.httpMethod = "POST"
        req.httpBody = Data(text.utf8)
        req.setValue(title, forHTTPHeaderField: "Title")
        req.setValue("warning,footprints", forHTTPHeaderField: "Tags")
        req.timeoutInterval = 8
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}

// MARK: - Banner

/// iOS-notification-style banner: family avatar, "Sent to Mom", the message, delivery state.
struct FamilyBanner: View {
    let notice: FamilyNotice
    let contact: FamilyContact

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                FamilyAvatar(name: contact.name)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(color, in: Circle())
                    .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 2))
                    .offset(x: 4, y: 4)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(headline).font(.subheadline.weight(.bold))
                    Spacer()
                    Text("now").font(.caption2).opacity(0.6)
                }
                Text(notice.message)
                    .font(.footnote)
                    .opacity(0.85)
                    .lineLimit(2)
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        switch notice.state {
        case .sending: return L("Sending to \(contact.name)…")
        case .delivered: return L("Sent to \(contact.name)")
        case .failed: return L("Couldn't reach \(contact.name)")
        }
    }

    private var icon: String {
        switch notice.state {
        case .sending: return "arrow.up"
        case .delivered: return "checkmark"
        case .failed: return "exclamationmark"
        }
    }

    private var color: Color {
        switch notice.state {
        case .sending: return Palette.info
        case .delivered: return Palette.clear
        case .failed: return Palette.danger
        }
    }
}

// MARK: - Settings

struct FamilySettingsView: View {
    @ObservedObject var family: FamilyNotifier
    @State private var testState: String?
    @State private var photoItem: PhotosPickerItem?
    @AppStorage("family.avatarVersion") private var avatarVersion = 0

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        FamilyAvatar(name: family.name, size: 64)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "camera.fill").font(.caption2)
                                    .padding(5).background(Palette.info, in: Circle())
                            }
                    }
                    TextField("Name", text: $family.name)
                        .font(.title3.weight(.semibold))
                }
                .onChange(of: photoItem) {
                    Task {
                        guard let data = try? await photoItem?.loadTransferable(type: Data.self),
                              let img = UIImage(data: data),
                              let png = img.preparingThumbnail(of: CGSize(width: 256, height: 256 * img.size.height / img.size.width))?.pngData()
                        else { return }
                        try? png.write(to: FamilyAvatar.fileURL, options: .atomic)
                        await MainActor.run { avatarVersion += 1 }
                    }
                }
            } header: {
                Text("Who gets alerts")
            }

            Section {
                Toggle("Auto-notify family", isOn: $family.enabled)
                Stepper("For steps ≥ \(Int(family.minCm)) cm", value: $family.minCm, in: 8...30, step: 1)
            } footer: {
                Text("Sends the step type, height and time only. No location or photo. At most one alert every 30 seconds.")
            }

            Section {
                LabeledContent("Channel", value: family.topic)
                    .font(.footnote.monospaced())
                ShareLink(item: family.link,
                          message: Text("Open this link (or subscribe in the free ntfy app) to get MindTheStep alerts.")) {
                    Label("Send setup link to \(family.name)", systemImage: "square.and.arrow.up")
                }
                Button {
                    testState = L("Sending…")
                    Task {
                        let ok = await family.send(L("This is a test alert from MindTheStep."), title: L("MindTheStep test"))
                        await MainActor.run { testState = ok ? L("Delivered ✓") : L("Failed. Check internet.") }
                    }
                } label: {
                    HStack {
                        Label("Send test alert", systemImage: "bell.badge")
                        Spacer()
                        if let testState { Text(testState).foregroundStyle(.secondary) }
                    }
                }
            } header: {
                Text("Delivery")
            } footer: {
                Text("\(family.name) opens the link in a browser, or subscribes to the channel in the free ntfy app for push notifications.")
            }

            Section("Recent alerts") {
                if family.sent.isEmpty {
                    Text("Alerts sent to \(family.name) will appear here.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(family.sent.prefix(10)) { a in
                        HStack(alignment: .top, spacing: 10) {
                            FamilyAvatar(name: family.name, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.text).font(.subheadline)
                                HStack(spacing: 4) {
                                    Image(systemName: a.delivered ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                        .foregroundStyle(a.delivered ? Palette.clear : Palette.danger)
                                    Text(a.delivered ? L("Delivered") : L("Not delivered"))
                                    Text(a.date, style: .time)
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}
