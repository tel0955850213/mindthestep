import Foundation

/// Looks a string up in Localizable.xcstrings (English is the source language).
func L(_ key: String.LocalizationValue) -> String { String(localized: key) }

enum Lang {
    /// True when the user's first preferred language is Chinese; used for voice cues and AI text.
    static var isChinese: Bool { (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") }
}

/// The detector reports reasons in English (they are stable identifiers); translate them for display.
func localizedReason(_ reason: String) -> String {
    let prefix = "Ground not visible past "
    if reason.hasPrefix(prefix) {
        let n = reason.dropFirst(prefix.count).replacingOccurrences(of: " m", with: "")
        return L("Ground not visible past \(n) m")
    }
    switch reason {
    case "Can't see the ground ahead": return L("Can't see the ground ahead")
    case "Hold the phone at chest height": return L("Hold the phone at chest height")
    case "Not enough ground points": return L("Not enough ground points")
    case "Obstacle ahead": return L("Obstacle ahead")
    case "Large drop or obstacle ahead": return L("Large drop or obstacle ahead")
    case "Edge partly hidden": return L("Edge partly hidden")
    case "Waiting for depth", "No depth this frame": return L("Waiting for depth")
    default: return reason
    }
}
