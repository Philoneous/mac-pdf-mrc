// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

enum OutputMode: String, Codable {
    case copy     // "<Name><Zusatz>.pdf" neben dem Original
    case replace  // Original in den Papierkorb, Ergebnis an seine Stelle
}

/// Ein Satz Einstellungen. Standardwerte = Standardwerte von paperless-mrc.
struct Profile: Codable, Equatable {
    // Texterkennung
    var languages = "deu+eng"  // mitgeliefert; weitere in der App nachladbar
    var keepTextLayer = true
    var rotate = true
    var rotateThreshold = 12.0
    var deskew = true
    var deskewMinAngle = 0.2
    var deskewMaxAngle = 5.0
    var deskewConfidence = 1.3
    // Seitenauswahl
    var mixedPdfs = true
    var skipPhotos = true
    var photoPaperPercent = 50.0
    var photoMinWords = 10
    var vectorPages = true
    var vectorMinItems = 1000
    var vectorDpi = 300
    // Leere Seiten
    var removeBlank = true
    var blankInkPercent = 0.005
    var blankPaperPercent = 90.0
    // Qualität und Größe
    var bgDownsample = 2
    var bgRate = 200.0
    var fitA4 = true
    var maxDpi = 0  // 0 = aus
    var sharpen = 150  // %, 0 = aus
    var sharpenRadius = 1.5
    var maskFactor = 0.5
    var jobs = 0  // gleichzeitig verarbeitete Seiten; 0 = automatisch (Anzahl Kerne)
    // Ausgabe
    var output = OutputMode.copy
    var suffix = " (komprimiert)"

    init() {}

    /// Fehlende Schlüssel (Einstellungsdatei einer älteren Version) erhalten den Standardwert,
    /// statt alle gespeicherten Einstellungen zu verwerfen.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Profile()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        languages = try value(.languages, d.languages)
        keepTextLayer = try value(.keepTextLayer, d.keepTextLayer)
        rotate = try value(.rotate, d.rotate)
        rotateThreshold = try value(.rotateThreshold, d.rotateThreshold)
        deskew = try value(.deskew, d.deskew)
        deskewMinAngle = try value(.deskewMinAngle, d.deskewMinAngle)
        deskewMaxAngle = try value(.deskewMaxAngle, d.deskewMaxAngle)
        deskewConfidence = try value(.deskewConfidence, d.deskewConfidence)
        mixedPdfs = try value(.mixedPdfs, d.mixedPdfs)
        skipPhotos = try value(.skipPhotos, d.skipPhotos)
        photoPaperPercent = try value(.photoPaperPercent, d.photoPaperPercent)
        photoMinWords = try value(.photoMinWords, d.photoMinWords)
        vectorPages = try value(.vectorPages, d.vectorPages)
        vectorMinItems = try value(.vectorMinItems, d.vectorMinItems)
        vectorDpi = try value(.vectorDpi, d.vectorDpi)
        removeBlank = try value(.removeBlank, d.removeBlank)
        blankInkPercent = try value(.blankInkPercent, d.blankInkPercent)
        blankPaperPercent = try value(.blankPaperPercent, d.blankPaperPercent)
        bgDownsample = try value(.bgDownsample, d.bgDownsample)
        bgRate = try value(.bgRate, d.bgRate)
        fitA4 = try value(.fitA4, d.fitA4)
        maxDpi = try value(.maxDpi, d.maxDpi)
        sharpen = try value(.sharpen, d.sharpen)
        sharpenRadius = try value(.sharpenRadius, d.sharpenRadius)
        maskFactor = try value(.maskFactor, d.maskFactor)
        jobs = try value(.jobs, d.jobs)
        output = try value(.output, d.output)
        suffix = try value(.suffix, d.suffix)
    }

    /// Umgebungsvariablen, über die paperless-mrc die Einstellungen liest.
    var environment: [String: String] {
        func flag(_ on: Bool) -> String { on ? "true" : "false" }
        var env = [
            "PAPERLESS_OCR_LANGUAGE": languages.trimmingCharacters(in: .whitespaces),
            "PAPERLESS_OCR_ROTATE_PAGES": flag(rotate),
            "PAPERLESS_OCR_ROTATE_PAGES_THRESHOLD": String(rotateThreshold),
            "PAPERLESS_OCR_DESKEW": flag(deskew),
            "MRC_KEEP_TEXT_LAYER": flag(keepTextLayer),
            "MRC_DESKEW_MIN_ANGLE": String(deskewMinAngle),
            "MRC_DESKEW_MAX_ANGLE": String(deskewMaxAngle),
            "MRC_DESKEW_MIN_CONFIDENCE": String(deskewConfidence),
            "MRC_MIXED_PDFS": flag(mixedPdfs),
            "MRC_SKIP_PHOTOS": flag(skipPhotos),
            "MRC_PHOTO_PAPER_PERCENT": String(photoPaperPercent),
            "MRC_PHOTO_MIN_WORDS": String(photoMinWords),
            "MRC_VECTOR_PAGES": flag(vectorPages),
            "MRC_VECTOR_MIN_ITEMS": String(vectorMinItems),
            "MRC_VECTOR_DPI": String(vectorDpi),
            "MRC_REMOVE_BLANK_PAGES": flag(removeBlank),
            "MRC_BLANK_INK_PERCENT": String(blankInkPercent),
            "MRC_BLANK_PAPER_PERCENT": String(blankPaperPercent),
            "MRC_BG_DOWNSAMPLE": String(bgDownsample),
            "MRC_BG_COMPRESSION_RATE": String(bgRate),
            "MRC_FIT_A4": flag(fitA4),
            "MRC_MAX_DPI": String(maxDpi),
            "MRC_SHARPEN": String(sharpen),
            "MRC_SHARPEN_RADIUS": String(sharpenRadius),
            "MRC_MASK_FACTOR": String(maskFactor),
        ]
        if jobs > 0 {
            env["PAPERLESS_THREADS_PER_WORKER"] = String(jobs)
        }
        return env
    }
}

/// Zwei Profile: manuelle Umwandlung in der App und Finder-Schnellaktion.
/// Gespeichert als JSON, damit auch der Aufruf aus dem Kontextmenü sie lesen kann.
struct AppSettings: Codable, Equatable {
    var manual = Profile()
    var quickAction = Profile()
    var paperlessURL = ""  // API-Token liegt im Schlüsselbund (PaperlessToken)

    init() {}

    /// Fehlende Schlüssel (ältere Version) erhalten den Standardwert.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manual = try c.decodeIfPresent(Profile.self, forKey: .manual) ?? Profile()
        quickAction = try c.decodeIfPresent(Profile.self, forKey: .quickAction) ?? Profile()
        paperlessURL = try c.decodeIfPresent(String.self, forKey: .paperlessURL) ?? ""
    }

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
