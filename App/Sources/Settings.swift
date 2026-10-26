// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

enum OutputMode: String, Codable {
    case copy     // "<Name><Zusatz>.pdf" neben dem Original
    case replace  // Original in den Papierkorb, Ergebnis an seine Stelle
}

/// Ein Satz Einstellungen. Standardwerte = Standardwerte von paperless-mrc.
struct Profile: Codable, Equatable {
    var languages = "deu+eng+pol"
    var rotate = true
    var deskew = true
    var removeBlank = true
    var blankInkPercent = 0.005
    var bgDownsample = 2
    var bgRate = 200.0
    var fitA4 = true
    var output = OutputMode.copy
    var suffix = " (komprimiert)"

    /// Umgebungsvariablen, über die paperless-mrc die Einstellungen liest.
    var environment: [String: String] {
        [
            "PAPERLESS_OCR_LANGUAGE": languages.trimmingCharacters(in: .whitespaces),
            "PAPERLESS_OCR_ROTATE_PAGES": rotate ? "true" : "false",
            "PAPERLESS_OCR_DESKEW": deskew ? "true" : "false",
            "MRC_REMOVE_BLANK_PAGES": removeBlank ? "true" : "false",
            "MRC_BLANK_INK_PERCENT": String(blankInkPercent),
            "MRC_BG_DOWNSAMPLE": String(bgDownsample),
            "MRC_BG_COMPRESSION_RATE": String(bgRate),
            "MRC_FIT_A4": fitA4 ? "true" : "false",
        ]
    }
}

/// Zwei Profile: manuelle Umwandlung in der App und Finder-Schnellaktion.
/// Gespeichert als JSON, damit auch der Aufruf aus dem Kontextmenü sie lesen kann.
struct AppSettings: Codable, Equatable {
    var manual = Profile()
    var quickAction = Profile()

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/mac-pdf-mrc/settings.json")

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url, options: .atomic)
    }
}

final class SettingsStore: ObservableObject {
    @Published var settings = AppSettings.load() {
        didSet { try? settings.save() }
    }
}
